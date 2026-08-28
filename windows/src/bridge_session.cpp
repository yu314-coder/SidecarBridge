#include "bridge_session.h"

#include <cctype>
#include <sstream>
#include <utility>

BridgeSession::BridgeSession(EventHandler eventHandler, WindowsTransport& transport)
    : eventHandler_(std::move(eventHandler)), transport_(transport) {}

void BridgeSession::handleMessage(const std::string& message) {
    const std::string type = jsonStringValue(message, "type");

    if (type == "ready") {
        transport_.start();
        sendInitialState();
        return;
    }

    if (type == "disconnect") {
        transport_.disconnect();
        sendState(
            "idle",
            "Waiting for iPad",
            "The Windows host is listening on TCP 45454. Select this device in SidecarBridge on your iPad.",
            false,
            false
        );
        return;
    }

    if (type == "connect") {
        sendState("pairing", "Waiting for iPad", "The pairing code is shown in this host window. Select this Windows device from the iPad app to connect.", false, false);
    }
}

void BridgeSession::sendInitialState() const {
    sendState(
        "idle",
        "Waiting for iPad",
        std::string("The encrypted Windows host is listening on TCP 45454. Pairing code: ") + transport_.pairingCode(),
        false,
        false
    );
}

void BridgeSession::sendState(
    const char* state,
    const char* headline,
    const std::string& detail,
    bool connected,
    bool pairingRequired
) const {
    if (!eventHandler_) {
        return;
    }

    std::ostringstream payload;
    payload << "{\"type\":\"state\""
            << ",\"state\":\"" << escapeJson(state) << "\""
            << ",\"headline\":\"" << escapeJson(headline) << "\""
            << ",\"detail\":\"" << escapeJson(detail) << "\""
            << ",\"connected\":" << (connected ? "true" : "false")
            << ",\"pairingRequired\":" << (pairingRequired ? "true" : "false")
            << "}";
    eventHandler_(payload.str());
}

void BridgeSession::sendError(const char* message) const {
    if (!eventHandler_) {
        return;
    }

    std::ostringstream payload;
    payload << "{\"type\":\"error\",\"message\":\""
            << escapeJson(message) << "\"}";
    eventHandler_(payload.str());
}

std::string BridgeSession::jsonStringValue(const std::string& json, const char* key) {
    const std::string quotedKey = std::string("\"") + key + "\"";
    const size_t keyPosition = json.find(quotedKey);
    if (keyPosition == std::string::npos) {
        return {};
    }

    const size_t colon = json.find(':', keyPosition + quotedKey.size());
    if (colon == std::string::npos) {
        return {};
    }

    size_t cursor = colon + 1;
    while (cursor < json.size() && std::isspace(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }
    if (cursor >= json.size() || json[cursor] != '"') {
        return {};
    }

    ++cursor;
    std::string value;
    bool escaped = false;
    for (; cursor < json.size(); ++cursor) {
        const char character = json[cursor];
        if (!escaped && character == '"') {
            break;
        }
        if (!escaped && character == '\\') {
            escaped = true;
            continue;
        }
        if (escaped) {
            switch (character) {
            case '"':
            case '\\':
            case '/':
                value.push_back(character);
                break;
            case 'n':
                value.push_back('\n');
                break;
            case 'r':
                value.push_back('\r');
                break;
            case 't':
                value.push_back('\t');
                break;
            default:
                value.push_back(character);
                break;
            }
            escaped = false;
            continue;
        }
        value.push_back(character);
    }
    return value;
}

std::string BridgeSession::normalizePairingCode(const std::string& value) {
    std::string digits;
    digits.reserve(value.size());
    for (const char character : value) {
        if (character >= '0' && character <= '9') {
            digits.push_back(character);
        }
    }
    return digits;
}

std::string BridgeSession::escapeJson(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.size());
    for (const char character : value) {
        switch (character) {
        case '"':
            escaped += "\\\"";
            break;
        case '\\':
            escaped += "\\\\";
            break;
        case '\n':
            escaped += "\\n";
            break;
        case '\r':
            escaped += "\\r";
            break;
        case '\t':
            escaped += "\\t";
            break;
        default:
            escaped.push_back(character);
            break;
        }
    }
    return escaped;
}
