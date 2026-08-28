#include <windows.h>

#include <filesystem>
#include <string>

#include "bridge_session.h"
#include "webview.h"

namespace {

std::filesystem::path executableDirectory() {
    std::wstring buffer(512, L'\0');
    for (;;) {
        const DWORD length = GetModuleFileNameW(
            nullptr,
            buffer.data(),
            static_cast<DWORD>(buffer.size())
        );
        if (length == 0) {
            return {};
        }
        if (length < buffer.size() - 1) {
            buffer.resize(length);
            return std::filesystem::path(buffer).parent_path();
        }
        buffer.resize(buffer.size() * 2);
    }
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    const HRESULT comResult = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(comResult)) {
        return 1;
    }

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    const std::filesystem::path executablePath = executableDirectory();
    std::filesystem::path webRoot = executablePath / L"web";
    if (!std::filesystem::is_directory(webRoot)) {
        webRoot = std::filesystem::current_path() / L"web";
    }
    std::filesystem::path fixedRuntimePath = executablePath / L"WebView2Runtime";
    std::wstring fixedRuntimePathString;
    if (std::filesystem::is_regular_file(fixedRuntimePath / L"msedgewebview2.exe")) {
        fixedRuntimePathString = fixedRuntimePath.wstring();
    }

    WebViewHost host;
    BridgeSession session([&host](const std::string& event) {
        host.postJson(event);
    });

    const bool created = host.create(
        instance,
        L"SidecarBridge — Windows companion",
        webRoot.wstring(),
        fixedRuntimePathString,
        [&session](const std::string& message) {
            session.handleMessage(message);
        }
    );

    if (!created) {
        CoUninitialize();
        return 1;
    }

    const int result = host.run();
    CoUninitialize();
    return result;
}
