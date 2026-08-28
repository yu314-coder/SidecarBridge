#include "webview.h"

#include <shellapi.h>

#include <algorithm>
#include <utility>

namespace {

constexpr wchar_t kWindowClassName[] = L"SidecarBridgeWindowsWebViewHost";
constexpr wchar_t kVirtualHostName[] = L"app.sidecarbridge.local";

} // namespace

bool WebViewHost::create(
    HINSTANCE instance,
    const std::wstring& title,
    const std::wstring& webRoot,
    const std::wstring& fixedRuntimePath,
    MessageHandler messageHandler
) {
    instance_ = instance;
    webRoot_ = webRoot;
    fixedRuntimePath_ = fixedRuntimePath;
    messageHandler_ = std::move(messageHandler);

    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.style = CS_HREDRAW | CS_VREDRAW;
    windowClass.lpfnWndProc = &WebViewHost::windowProc;
    windowClass.hInstance = instance_;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    windowClass.lpszClassName = kWindowClassName;

    WNDCLASSEXW existingClass{};
    existingClass.cbSize = sizeof(existingClass);
    if (!GetClassInfoExW(instance_, kWindowClassName, &existingClass)) {
        if (!RegisterClassExW(&windowClass)) {
            return false;
        }
    }

    window_ = CreateWindowExW(
        0,
        kWindowClassName,
        title.c_str(),
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1180,
        820,
        nullptr,
        nullptr,
        instance_,
        this
    );
    if (!window_) {
        return false;
    }

    ShowWindow(window_, SW_SHOWDEFAULT);
    UpdateWindow(window_);

    const wchar_t* browserExecutableFolder = nullptr;
    if (!fixedRuntimePath_.empty()) {
        browserExecutableFolder = fixedRuntimePath_.c_str();
    }
    const HRESULT environmentResult = CreateCoreWebView2EnvironmentWithOptions(
        browserExecutableFolder,
        nullptr,
        nullptr,
        Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [this](HRESULT errorCode, ICoreWebView2Environment* environment) -> HRESULT {
                if (FAILED(errorCode) || environment == nullptr) {
                    showInitializationError(L"CreateCoreWebView2EnvironmentWithOptions", errorCode);
                    return FAILED(errorCode) ? errorCode : E_FAIL;
                }

                environment_ = environment;
                return environment_->CreateCoreWebView2Controller(
                    window_,
                    Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [this](HRESULT controllerError, ICoreWebView2Controller* controller) -> HRESULT {
                            if (FAILED(controllerError) || controller == nullptr) {
                                showInitializationError(L"CreateCoreWebView2Controller", controllerError);
                                return FAILED(controllerError) ? controllerError : E_FAIL;
                            }

                            controller_ = controller;
                            HRESULT result = controller_->get_CoreWebView2(&webView_);
                            if (FAILED(result) || webView_ == nullptr) {
                                showInitializationError(L"get_CoreWebView2", result);
                                return FAILED(result) ? result : E_FAIL;
                            }

                            Microsoft::WRL::ComPtr<ICoreWebView2Settings> settings;
                            if (SUCCEEDED(webView_->get_Settings(&settings)) && settings != nullptr) {
                                settings->put_IsScriptEnabled(TRUE);
                                settings->put_AreDefaultScriptDialogsEnabled(TRUE);
                                settings->put_IsWebMessageEnabled(TRUE);
                                settings->put_AreDevToolsEnabled(FALSE);
                            }

                            result = webView_->add_WebMessageReceived(
                                Microsoft::WRL::Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                    [this](
                                        ICoreWebView2*,
                                        ICoreWebView2WebMessageReceivedEventArgs* arguments
                                    ) -> HRESULT {
                                        LPWSTR rawMessage = nullptr;
                                        const HRESULT messageResult =
                                            arguments->TryGetWebMessageAsString(&rawMessage);
                                        if (SUCCEEDED(messageResult) && rawMessage != nullptr) {
                                            if (messageHandler_) {
                                                messageHandler_(wideToUtf8(rawMessage));
                                            }
                                            CoTaskMemFree(rawMessage);
                                        }
                                        return S_OK;
                                    }
                                ).Get(),
                                &webMessageToken_
                            );
                            if (FAILED(result)) {
                                showInitializationError(L"add_WebMessageReceived", result);
                                return result;
                            }

                            Microsoft::WRL::ComPtr<ICoreWebView2_3> extendedWebView;
                            if (SUCCEEDED(webView_.As(&extendedWebView)) && extendedWebView != nullptr) {
                                result = extendedWebView->SetVirtualHostNameToFolderMapping(
                                    kVirtualHostName,
                                    webRoot_.c_str(),
                                    COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW
                                );
                                if (FAILED(result)) {
                                    showInitializationError(L"SetVirtualHostNameToFolderMapping", result);
                                    return result;
                                }
                            }

                            resizeController();
                            webView_->Navigate((std::wstring(L"https://") + kVirtualHostName + L"/index.html").c_str());
                            return S_OK;
                        }
                    ).Get()
                );
            }
        ).Get()
    );

    if (FAILED(environmentResult)) {
        showInitializationError(L"CreateCoreWebView2EnvironmentWithOptions", environmentResult);
        return false;
    }
    return true;
}

int WebViewHost::run() const {
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return static_cast<int>(message.wParam);
}

void WebViewHost::postJson(const std::string& json) const {
    if (webView_ == nullptr) {
        return;
    }
    const std::wstring wideJson = utf8ToWide(json);
    webView_->PostWebMessageAsJson(wideJson.c_str());
}

LRESULT CALLBACK WebViewHost::windowProc(
    HWND window,
    UINT message,
    WPARAM wParam,
    LPARAM lParam
) {
    auto* host = reinterpret_cast<WebViewHost*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        const auto* createStruct = reinterpret_cast<CREATESTRUCTW*>(lParam);
        host = static_cast<WebViewHost*>(createStruct->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(host));
        host->window_ = window;
    }

    if (host != nullptr) {
        switch (message) {
        case WM_SIZE:
            host->resizeController();
            break;
        case WM_CLOSE:
            DestroyWindow(window);
            return 0;
        case WM_DESTROY:
            if (host->webView_ != nullptr) {
                host->webView_->remove_WebMessageReceived(host->webMessageToken_);
            }
            PostQuitMessage(0);
            return 0;
        default:
            break;
        }
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

void WebViewHost::resizeController() const {
    if (controller_ == nullptr || window_ == nullptr) {
        return;
    }

    RECT bounds{};
    GetClientRect(window_, &bounds);
    controller_->put_Bounds(bounds);
}

void WebViewHost::showInitializationError(const wchar_t* operation, HRESULT error) const {
    wchar_t message[256]{};
    swprintf_s(
        message,
        L"%ls failed (HRESULT 0x%08lX). The bundled WebView2 runtime was not available; install the WebView2 Runtime and retry.",
        operation,
        static_cast<unsigned long>(error)
    );
    MessageBoxW(window_, message, L"SidecarBridge Windows", MB_ICONERROR | MB_OK);
}

std::wstring WebViewHost::utf8ToWide(const std::string& value) {
    if (value.empty()) {
        return {};
    }
    const int length = MultiByteToWideChar(
        CP_UTF8,
        MB_ERR_INVALID_CHARS,
        value.data(),
        static_cast<int>(value.size()),
        nullptr,
        0
    );
    if (length <= 0) {
        return {};
    }
    std::wstring result(static_cast<size_t>(length), L'\0');
    MultiByteToWideChar(
        CP_UTF8,
        MB_ERR_INVALID_CHARS,
        value.data(),
        static_cast<int>(value.size()),
        result.data(),
        length
    );
    return result;
}

std::string WebViewHost::wideToUtf8(const wchar_t* value) {
    if (value == nullptr || *value == L'\0') {
        return {};
    }
    const int length = WideCharToMultiByte(
        CP_UTF8,
        WC_ERR_INVALID_CHARS,
        value,
        -1,
        nullptr,
        0,
        nullptr,
        nullptr
    );
    if (length <= 1) {
        return {};
    }
    std::string result(static_cast<size_t>(length - 1), '\0');
    WideCharToMultiByte(
        CP_UTF8,
        WC_ERR_INVALID_CHARS,
        value,
        -1,
        result.data(),
        length - 1,
        nullptr,
        nullptr
    );
    return result;
}
