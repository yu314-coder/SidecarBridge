#pragma once

#include <functional>
#include <string>

#include "bridge_transport.h"

// Transport-agnostic state model for the Windows companion.  The native
// transport owns the listener and pairing state; this class only bridges those
// events to the WebView dashboard and keeps the pairing code copyable.
class BridgeSession final {
public:
    using EventHandler = std::function<void(const std::string&)>;

    BridgeSession(EventHandler eventHandler, WindowsTransport& transport);

    void handleMessage(const std::string& message);
    void sendInitialState() const;

private:
    void sendState(
        const char* state,
        const char* headline,
        const std::string& detail,
        bool connected,
        bool pairingRequired
    ) const;
    void sendError(const char* message) const;

    static std::string jsonStringValue(const std::string& json, const char* key);
    static std::string normalizePairingCode(const std::string& value);
    static std::string escapeJson(const std::string& value);

    EventHandler eventHandler_;
    WindowsTransport& transport_;
};
