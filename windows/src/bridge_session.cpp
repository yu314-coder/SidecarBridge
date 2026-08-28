#include "bridge_session.h"

#include <cctype>
#include <sstream>
#include <utility>

BridgeSession::BridgeSession(EventHandler eventHandler)
    : eventHandler_(std::move(eventHandler)) {}

void BridgeSession::handleMessage(const std::string& message) {
    const std::string type = jsonStringValue(message, "type");

    if (type == "ready") {
        sendInitialState();
        return;
    }

    if (type == "disconnect") {
        sendState(
            "idle",
            "Ready for a Windows transport",
            "Choose Connect after entering the 16-digit pairing code.",
            false,
            true
        );
        return;
    }

    if (type != "connect") {
        return;
    }

    const std::string pairingCode = normalizePairingCode(jsonStringValue(message, "pairingCode"));
    if (pairingCode.size() != 16) {
        sendError("Enter the 16-digit pairing code. Dashes are accepted.");
        return;
    }

    // This is intentionally a ready-to-wire state, not a false connection.
    // The next slice will attach LAN discovery, capture, input, and file
    // transfer to this same protocol boundary.
    sendState(
        "ready",
        "Pairing code accepted",
        "The Windows transport backend is not connected yet. LAN discovery is next.",
        false,
        false
    );
}

void BridgeSession::sendInitialState() const {
    sendState(
        "idle",
        "Windows companion shell is ready",
        "The WebView dashboard loaded successfully. Enter a pairing code to continue.",
        false,
        true
    );
}

void BridgeSession::sendState(
    const char* state,
    const char* headline,
    const char* detail,
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
