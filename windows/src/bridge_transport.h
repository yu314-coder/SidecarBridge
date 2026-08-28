#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Windows host transport for the public SidecarBridge LAN protocol.  It is
// deliberately independent from WebView2 so the tray/background host can
// keep accepting an iPad while the dashboard is hidden.  The wire format is
// the same v3 X25519 + HKDF-SHA256 + ChaCha20-Poly1305 protocol used by the
// macOS host (TCP 45454, _sb-direct._tcp).
class WindowsTransport final {
public:
    using EventHandler = std::function<void(const std::string&)>;

    explicit WindowsTransport(EventHandler eventHandler);
    ~WindowsTransport();

    WindowsTransport(const WindowsTransport&) = delete;
    WindowsTransport& operator=(const WindowsTransport&) = delete;

    void start();
    void stop();
    void disconnect();
    std::string pairingCode() const;
    std::string localAddress() const;

private:
    struct Session;

    void run();
    void discoveryLoop();
    void acceptLoop();
    void handleClient(uintptr_t socket);
    void captureLoop(std::shared_ptr<Session> session);
    void emit(const std::string& json) const;
    void emitState(const char* state, const char* headline, const char* detail,
                   bool connected) const;

    EventHandler eventHandler_;
    std::atomic<bool> running_{false};
    std::atomic<bool> stopRequested_{false};
    std::thread worker_;
    std::thread captureWorker_;
    std::thread discoveryWorker_;
    std::atomic<uintptr_t> discoverySocket_{0};
    mutable std::mutex sessionMutex_;
    std::shared_ptr<Session> session_;
    std::string pairingCode_;
    std::string macID_;
    std::string localAddress_;
};
