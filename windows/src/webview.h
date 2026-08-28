#pragma once

#include <windows.h>

#include <WebView2.h>
#include <wrl.h>

#include <functional>
#include <string>

// Small Win32/WebView2 host used by the Windows companion shell.  Keeping the
// browser boundary in this header makes it possible to replace WebView2 with
// another webview implementation later without coupling the bridge session to
// Win32 windowing details.
class WebViewHost final {
public:
    using MessageHandler = std::function<void(const std::string&)>;

    bool create(
        HINSTANCE instance,
        const std::wstring& title,
        const std::wstring& webRoot,
        const std::wstring& fixedRuntimePath,
        MessageHandler messageHandler
    );

    int run() const;
    void postJson(const std::string& json) const;
    HWND window() const { return window_; }

private:
    static LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    void resizeController() const;
    void showInitializationError(const wchar_t* operation, HRESULT error) const;

    static std::wstring utf8ToWide(const std::string& value);
    static std::string wideToUtf8(const wchar_t* value);

    HINSTANCE instance_ = nullptr;
    HWND window_ = nullptr;
    std::wstring webRoot_;
    // Keep the fixed WebView2 path alive for the asynchronous environment
    // creation call. An empty path intentionally falls back to Evergreen.
    std::wstring fixedRuntimePath_;
    MessageHandler messageHandler_;

    Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment_;
    Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller_;
    Microsoft::WRL::ComPtr<ICoreWebView2> webView_;
    EventRegistrationToken webMessageToken_{};
};
