#include "bridge_transport.h"

#ifndef _WIN32
#error "bridge_transport.cpp is a Windows-only source file"
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>
#include <shlwapi.h>
#include <wincodec.h>
#include <wincrypt.h>

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/kdf.h>
#include <openssl/rand.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <cmath>
#include <iomanip>
#include <iterator>
#include <map>
#include <sstream>
#include <utility>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "crypt32.lib")

namespace {

constexpr uint8_t kClientHello = 0xA1;
constexpr uint8_t kServerHello = 0xA2;
constexpr uint8_t kEncrypted = 0xA3;
constexpr uint8_t kEnvelope = 0xE1;
constexpr uint8_t kProtocolVersion = 3;
constexpr uint8_t kControlPacket = 1;
constexpr uint8_t kJpegPacket = 2;
constexpr uint8_t kFilePacket = 4;
constexpr uint8_t kAuthenticationPacket = 5;
constexpr size_t kMaximumPayload = 12 * 1024 * 1024;
constexpr size_t kMaximumClipboardBytes = 48 * 1024;
constexpr char kBindingContext[] = "SidecarBridge-LAN-binding-v2\0";
constexpr char kPairingContext[] = "SidecarBridge-Pairing-v2\0";
constexpr char kSecureContext[] = "SidecarBridge-secure-packet-v3\0";
constexpr char kHKDFContext[] = "SidecarBridge-LAN-v3\0";

using Bytes = std::vector<uint8_t>;

std::string escapeJson(const std::string& value) {
    std::string result;
    result.reserve(value.size());
    for (char c : value) {
        switch (c) {
        case '"': result += "\\\""; break;
        case '\\': result += "\\\\"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default: result += c; break;
        }
    }
    return result;
}

std::string jsonString(const std::string& json, const char* key) {
    const std::string needle = std::string("\"") + key + "\"";
    const size_t keyPos = json.find(needle);
    if (keyPos == std::string::npos) return {};
    const size_t colon = json.find(':', keyPos + needle.size());
    if (colon == std::string::npos) return {};
    size_t cursor = colon + 1;
    while (cursor < json.size() && std::isspace(static_cast<unsigned char>(json[cursor]))) ++cursor;
    if (cursor >= json.size() || json[cursor] != '"') return {};
    ++cursor;
    std::string result;
    bool escaped = false;
    for (; cursor < json.size(); ++cursor) {
        const char c = json[cursor];
        if (!escaped && c == '"') break;
        if (!escaped && c == '\\') { escaped = true; continue; }
        if (escaped) {
            switch (c) {
            case 'n': result += '\n'; break;
            case 'r': result += '\r'; break;
            case 't': result += '\t'; break;
            case '"': result += '"'; break;
            case '\\': result += '\\'; break;
            default: result += c; break;
            }
            escaped = false;
        } else {
            result += c;
        }
    }
    return result;
}

double jsonNumber(const std::string& json, const char* key, double fallback = 0.0) {
    const std::string needle = std::string("\"") + key + "\"";
    const size_t keyPos = json.find(needle);
    if (keyPos == std::string::npos) return fallback;
    const size_t colon = json.find(':', keyPos + needle.size());
    if (colon == std::string::npos) return fallback;
    char* end = nullptr;
    const double value = std::strtod(json.c_str() + colon + 1, &end);
    return end == json.c_str() + colon + 1 ? fallback : value;
}

bool jsonHasNumber(const std::string& json, const char* key) {
    const std::string needle = std::string("\"") + key + "\"";
    const size_t keyPos = json.find(needle);
    if (keyPos == std::string::npos) return false;
    const size_t colon = json.find(':', keyPos + needle.size());
    if (colon == std::string::npos) return false;
    const char* begin = json.c_str() + colon + 1;
    char* end = nullptr;
    std::strtod(begin, &end);
    return end != begin;
}

bool jsonArrayContains(const std::string& json, const char* key, const char* value) {
    const std::string needle = std::string("\"") + key + "\"";
    const size_t keyPos = json.find(needle);
    if (keyPos == std::string::npos) return false;
    const size_t colon = json.find(':', keyPos + needle.size());
    if (colon == std::string::npos) return false;
    const size_t start = json.find('[', colon + 1);
    const size_t end = start == std::string::npos ? std::string::npos : json.find(']', start + 1);
    if (start == std::string::npos || end == std::string::npos) return false;
    const std::string token = std::string("\"") + value + "\"";
    return json.find(token, start + 1) < end;
}

std::string truncateUtf8(std::string value, size_t maximumBytes) {
    if (value.size() <= maximumBytes) return value;
    value.resize(maximumBytes);
    // Never leave a partial UTF-8 scalar in a JSON string.  Continuation
    // bytes begin with 10xxxxxx; remove them until the scalar boundary.
    while (!value.empty() && (static_cast<unsigned char>(value.back()) & 0xC0) == 0x80) {
        value.pop_back();
    }
    return value;
}

std::string normalizeCode(const std::string& value) {
    std::string result;
    for (char c : value) if (c >= '0' && c <= '9') result += c;
    return result;
}

std::string formatCode(const std::string& digits) {
    std::string result;
    for (size_t i = 0; i < digits.size(); ++i) {
        if (i != 0 && i % 4 == 0) result += '-';
        result += digits[i];
    }
    return result;
}

std::string base64Encode(const Bytes& bytes) {
    if (bytes.empty()) return {};
    const int length = 4 * static_cast<int>((bytes.size() + 2) / 3);
    std::string result(static_cast<size_t>(length), '\0');
    const int written = EVP_EncodeBlock(reinterpret_cast<unsigned char*>(result.data()), bytes.data(),
                                         static_cast<int>(bytes.size()));
    return written > 0 ? result.substr(0, static_cast<size_t>(written)) : std::string{};
}

Bytes base64Decode(const std::string& encoded) {
    if (encoded.empty() || encoded.size() % 4 != 0) return {};
    Bytes result((encoded.size() / 4) * 3);
    const int length = EVP_DecodeBlock(result.data(),
                                       reinterpret_cast<const unsigned char*>(encoded.data()),
                                       static_cast<int>(encoded.size()));
    if (length < 0) return {};
    size_t padding = 0;
    if (!encoded.empty() && encoded.back() == '=') ++padding;
    if (encoded.size() > 1 && encoded[encoded.size() - 2] == '=') ++padding;
    result.resize(static_cast<size_t>(length) >= padding ? static_cast<size_t>(length) - padding : 0);
    return result;
}

void appendU32(Bytes& output, uint32_t value) {
    output.push_back(static_cast<uint8_t>(value >> 24));
    output.push_back(static_cast<uint8_t>(value >> 16));
    output.push_back(static_cast<uint8_t>(value >> 8));
    output.push_back(static_cast<uint8_t>(value));
}

void appendU64(Bytes& output, uint64_t value) {
    for (int shift = 56; shift >= 0; shift -= 8) output.push_back(static_cast<uint8_t>(value >> shift));
}

void appendU16(Bytes& output, uint16_t value) {
    output.push_back(static_cast<uint8_t>(value >> 8));
    output.push_back(static_cast<uint8_t>(value));
}

void appendDnsName(Bytes& output, const std::string& name) {
    size_t start = 0;
    while (start < name.size()) {
        const size_t dot = name.find('.', start);
        const size_t length = dot == std::string::npos ? name.size() - start : dot - start;
        if (length > 63) return;
        output.push_back(static_cast<uint8_t>(length));
        output.insert(output.end(), name.begin() + static_cast<std::ptrdiff_t>(start),
                      name.begin() + static_cast<std::ptrdiff_t>(start + length));
        if (dot == std::string::npos) break;
        start = dot + 1;
    }
    output.push_back(0);
}

void appendDnsRecord(Bytes& output, const std::string& owner, uint16_t type,
                     const Bytes& rdata, uint32_t ttl = 120) {
    appendDnsName(output, owner);
    appendU16(output, type);
    appendU16(output, 1); // IN
    output.push_back(static_cast<uint8_t>(ttl >> 24));
    output.push_back(static_cast<uint8_t>(ttl >> 16));
    output.push_back(static_cast<uint8_t>(ttl >> 8));
    output.push_back(static_cast<uint8_t>(ttl));
    appendU16(output, static_cast<uint16_t>(rdata.size()));
    output.insert(output.end(), rdata.begin(), rdata.end());
}

Bytes makeMDNSResponse(const std::array<uint8_t, 2>& queryID, const std::string& address,
                       const std::string& instance, const std::string& host) {
    Bytes response(queryID.begin(), queryID.end());
    appendU16(response, 0x8400); // response + authoritative
    appendU16(response, 1); // question
    appendU16(response, 4); // PTR, SRV, TXT, A
    appendU16(response, 0);
    appendU16(response, 0);
    appendDnsName(response, "_sb-direct._tcp.local");
    appendU16(response, 12); // PTR
    appendU16(response, 1);

    Bytes ptr; appendDnsName(ptr, instance + "._sb-direct._tcp.local");
    appendDnsRecord(response, "_sb-direct._tcp.local", 12, ptr);

    Bytes srv; appendU16(srv, 0); appendU16(srv, 0); appendU16(srv, 45454);
    appendDnsName(srv, host + ".local");
    appendDnsRecord(response, instance + "._sb-direct._tcp.local", 33, srv);

    Bytes txt;
    const std::string txtValues[] = {"sbp=3", "build=windows", std::string("hosts=") + address};
    for (const std::string& value : txtValues) {
        if (value.size() <= 255) { txt.push_back(static_cast<uint8_t>(value.size())); txt.insert(txt.end(), value.begin(), value.end()); }
    }
    appendDnsRecord(response, instance + "._sb-direct._tcp.local", 16, txt);

    in_addr parsed{};
    inet_pton(AF_INET, address.c_str(), &parsed);
    Bytes ipv4(reinterpret_cast<uint8_t*>(&parsed), reinterpret_cast<uint8_t*>(&parsed) + 4);
    appendDnsRecord(response, host + ".local", 1, ipv4);
    return response;
}

void appendLengthPrefixed(Bytes& output, const Bytes& value) {
    appendU32(output, static_cast<uint32_t>(value.size()));
    output.insert(output.end(), value.begin(), value.end());
}

void appendLengthPrefixed(Bytes& output, const std::string& value) {
    appendU32(output, static_cast<uint32_t>(value.size()));
    output.insert(output.end(), value.begin(), value.end());
}

bool randomBytes(Bytes& output, size_t count) {
    output.resize(count);
    return RAND_bytes(output.data(), static_cast<int>(count)) == 1;
}

bool sendAll(SOCKET socket, const uint8_t* data, size_t length) {
    while (length > 0) {
        const int chunk = send(socket, reinterpret_cast<const char*>(data),
                               static_cast<int>(std::min<size_t>(length, 1 << 20)), 0);
        if (chunk <= 0) return false;
        data += chunk;
        length -= static_cast<size_t>(chunk);
    }
    return true;
}

bool receiveAll(SOCKET socket, uint8_t* data, size_t length) {
    while (length > 0) {
        const int chunk = recv(socket, reinterpret_cast<char*>(data),
                               static_cast<int>(std::min<size_t>(length, 1 << 20)), MSG_WAITALL);
        if (chunk <= 0) return false;
        data += chunk;
        length -= static_cast<size_t>(chunk);
    }
    return true;
}

bool sendFrame(SOCKET socket, const Bytes& payload, std::mutex& sendMutex) {
    if (payload.empty() || payload.size() > kMaximumPayload) return false;
    Bytes frame;
    frame.reserve(4 + payload.size());
    appendU32(frame, static_cast<uint32_t>(payload.size()));
    frame.insert(frame.end(), payload.begin(), payload.end());
    std::lock_guard lock(sendMutex);
    return sendAll(socket, frame.data(), frame.size());
}

bool receiveFrame(SOCKET socket, Bytes& payload) {
    std::array<uint8_t, 4> header{};
    if (!receiveAll(socket, header.data(), header.size())) return false;
    const uint32_t length = (static_cast<uint32_t>(header[0]) << 24) |
                            (static_cast<uint32_t>(header[1]) << 16) |
                            (static_cast<uint32_t>(header[2]) << 8) |
                            static_cast<uint32_t>(header[3]);
    if (length == 0 || length > kMaximumPayload) return false;
    payload.resize(length);
    return receiveAll(socket, payload.data(), payload.size());
}

struct OpenSSLKeyDeleter {
    void operator()(EVP_PKEY* key) const { EVP_PKEY_free(key); }
};
using PKey = std::unique_ptr<EVP_PKEY, OpenSSLKeyDeleter>;

PKey makeX25519Key() {
    EVP_PKEY_CTX* context = EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, nullptr);
    if (!context) return {};
    PKey result;
    if (EVP_PKEY_keygen_init(context) == 1) {
        EVP_PKEY* raw = nullptr;
        if (EVP_PKEY_keygen(context, &raw) == 1) result.reset(raw);
    }
    EVP_PKEY_CTX_free(context);
    return result;
}

Bytes rawPublicKey(EVP_PKEY* key) {
    size_t length = 0;
    if (!key || EVP_PKEY_get_raw_public_key(key, nullptr, &length) != 1) return {};
    Bytes result(length);
    if (EVP_PKEY_get_raw_public_key(key, result.data(), &length) != 1) return {};
    result.resize(length);
    return result;
}

Bytes deriveSecret(EVP_PKEY* privateKey, const Bytes& peerPublicKey) {
    if (!privateKey || peerPublicKey.size() != 32) return {};
    PKey peer(EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, nullptr,
                                          peerPublicKey.data(), peerPublicKey.size()));
    if (!peer) return {};
    EVP_PKEY_CTX* context = EVP_PKEY_CTX_new(privateKey, nullptr);
    if (!context || EVP_PKEY_derive_init(context) != 1 ||
        EVP_PKEY_derive_set_peer(context, peer.get()) != 1) {
        if (context) EVP_PKEY_CTX_free(context);
        return {};
    }
    size_t length = 0;
    if (EVP_PKEY_derive(context, nullptr, &length) != 1) {
        EVP_PKEY_CTX_free(context);
        return {};
    }
    Bytes result(length);
    if (EVP_PKEY_derive(context, result.data(), &length) != 1) result.clear();
    result.resize(length);
    EVP_PKEY_CTX_free(context);
    return result;
}

Bytes hmacSha256(const Bytes& key, const Bytes& data) {
    unsigned int length = 0;
    Bytes result(EVP_MAX_MD_SIZE);
    if (!HMAC(EVP_sha256(), key.data(), static_cast<int>(key.size()), data.data(), data.size(),
              result.data(), &length)) return {};
    result.resize(length);
    return result;
}

Bytes hkdfSha256(const Bytes& secret, const Bytes& salt, const std::string& info) {
    EVP_PKEY_CTX* context = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, nullptr);
    if (!context) return {};
    Bytes result(32);
    const bool ok = EVP_PKEY_derive_init(context) == 1 &&
        EVP_PKEY_CTX_set_hkdf_md(context, EVP_sha256()) == 1 &&
        EVP_PKEY_CTX_set1_hkdf_salt(context, salt.data(), static_cast<int>(salt.size())) == 1 &&
        EVP_PKEY_CTX_set1_hkdf_key(context, secret.data(), static_cast<int>(secret.size())) == 1 &&
        EVP_PKEY_CTX_add1_hkdf_info(context, reinterpret_cast<const unsigned char*>(info.data()),
                                    static_cast<int>(info.size())) == 1;
    size_t length = result.size();
    const bool derived = ok && EVP_PKEY_derive(context, result.data(), &length) == 1;
    EVP_PKEY_CTX_free(context);
    if (!derived) return {};
    result.resize(length);
    return result;
}

Bytes channelBinding(const Bytes& clientPublic, const Bytes& serverPublic) {
    Bytes result(reinterpret_cast<const uint8_t*>(kBindingContext),
                 reinterpret_cast<const uint8_t*>(kBindingContext) + sizeof(kBindingContext) - 1);
    appendLengthPrefixed(result, clientPublic);
    appendLengthPrefixed(result, serverPublic);
    return result;
}

Bytes pairingTranscript(const std::string& role, const std::string& deviceID,
                        const std::string& deviceName, const std::string& deviceKind,
                        const std::string& macID, const Bytes& nonce, const Bytes& binding) {
    Bytes result(reinterpret_cast<const uint8_t*>(kPairingContext),
                 reinterpret_cast<const uint8_t*>(kPairingContext) + sizeof(kPairingContext) - 1);
    const std::string stableID = deviceID.empty()
        ? (deviceKind + ":" + deviceName)
        : deviceID;
    appendLengthPrefixed(result, role);
    appendLengthPrefixed(result, stableID);
    appendLengthPrefixed(result, deviceName);
    appendLengthPrefixed(result, deviceKind);
    appendLengthPrefixed(result, macID);
    appendLengthPrefixed(result, nonce);
    appendLengthPrefixed(result, binding);
    return result;
}

bool constantTimeEqual(const Bytes& lhs, const Bytes& rhs) {
    if (lhs.size() != rhs.size()) return false;
    unsigned int difference = 0;
    for (size_t i = 0; i < lhs.size(); ++i) difference |= lhs[i] ^ rhs[i];
    return difference == 0;
}

Bytes seal(const Bytes& key, uint8_t direction, uint64_t counter, const Bytes& plaintext) {
    Bytes header{kEnvelope, kProtocolVersion, direction};
    appendU64(header, counter);
    Bytes nonce{0, 0, 0, direction};
    appendU64(nonce, counter);
    Bytes aad(reinterpret_cast<const uint8_t*>(kSecureContext),
              reinterpret_cast<const uint8_t*>(kSecureContext) + sizeof(kSecureContext) - 1);
    aad.insert(aad.end(), header.begin(), header.end());

    EVP_CIPHER_CTX* context = EVP_CIPHER_CTX_new();
    if (!context) return {};
    Bytes ciphertext(plaintext.size() + 16);
    std::array<uint8_t, 16> tag{};
    int written = 0;
    int total = 0;
    bool ok = EVP_EncryptInit_ex(context, EVP_chacha20_poly1305(), nullptr, nullptr, nullptr) == 1 &&
              EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN, static_cast<int>(nonce.size()), nullptr) == 1 &&
              EVP_EncryptInit_ex(context, nullptr, nullptr, key.data(), nonce.data()) == 1 &&
              EVP_EncryptUpdate(context, nullptr, &written, aad.data(), static_cast<int>(aad.size())) == 1 &&
              EVP_EncryptUpdate(context, ciphertext.data(), &written, plaintext.data(), static_cast<int>(plaintext.size())) == 1;
    total = written;
    if (ok) ok = EVP_EncryptFinal_ex(context, ciphertext.data() + total, &written) == 1;
    total += written;
    if (ok) ok = EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_GET_TAG, static_cast<int>(tag.size()), tag.data()) == 1;
    EVP_CIPHER_CTX_free(context);
    if (!ok) return {};
    ciphertext.resize(static_cast<size_t>(total));
    Bytes result = header;
    result.insert(result.end(), ciphertext.begin(), ciphertext.end());
    result.insert(result.end(), tag.begin(), tag.end());
    return result;
}

Bytes openPacket(const Bytes& key, uint8_t expectedDirection, const Bytes& envelope,
                 uint64_t& highestCounter, uint64_t& receivedWindow) {
    if (envelope.size() < 1 + 1 + 1 + 8 + 16 || envelope[0] != kEnvelope ||
        envelope[1] != kProtocolVersion || envelope[2] != expectedDirection) return {};
    uint64_t counter = 0;
    for (size_t i = 0; i < 8; ++i) counter = (counter << 8) | envelope[3 + i];
    if (highestCounter != UINT64_MAX) {
        if (counter > highestCounter) {
            const uint64_t distance = counter - highestCounter;
            if (distance >= 64) receivedWindow = 1;
            else receivedWindow = (receivedWindow << distance) | 1;
            highestCounter = counter;
        } else {
            const uint64_t distance = highestCounter - counter;
            if (distance >= 64 || (receivedWindow & (uint64_t{1} << distance)) != 0) return {};
            receivedWindow |= uint64_t{1} << distance;
        }
    } else {
        highestCounter = counter;
        receivedWindow = 1;
    }
    const size_t tagOffset = envelope.size() - 16;
    Bytes header(envelope.begin(), envelope.begin() + 11);
    Bytes nonce{0, 0, 0, expectedDirection};
    appendU64(nonce, counter);
    Bytes aad(reinterpret_cast<const uint8_t*>(kSecureContext),
              reinterpret_cast<const uint8_t*>(kSecureContext) + sizeof(kSecureContext) - 1);
    aad.insert(aad.end(), header.begin(), header.end());
    EVP_CIPHER_CTX* context = EVP_CIPHER_CTX_new();
    if (!context) return {};
    Bytes plaintext(tagOffset - 11 + 16);
    int written = 0;
    int total = 0;
    bool ok = EVP_DecryptInit_ex(context, EVP_chacha20_poly1305(), nullptr, nullptr, nullptr) == 1 &&
              EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN, static_cast<int>(nonce.size()), nullptr) == 1 &&
              EVP_DecryptInit_ex(context, nullptr, nullptr, key.data(), nonce.data()) == 1 &&
              EVP_DecryptUpdate(context, nullptr, &written, aad.data(), static_cast<int>(aad.size())) == 1 &&
              EVP_DecryptUpdate(context, plaintext.data(), &written, envelope.data() + 11,
                                static_cast<int>(tagOffset - 11)) == 1 &&
              EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_TAG, 16,
                                  const_cast<uint8_t*>(envelope.data() + tagOffset)) == 1;
    total = written;
    if (ok) ok = EVP_DecryptFinal_ex(context, plaintext.data() + total, &written) == 1;
    total += written;
    EVP_CIPHER_CTX_free(context);
    if (!ok) return {};
    plaintext.resize(static_cast<size_t>(total));
    return plaintext;
}

std::string computerID() {
    wchar_t buffer[256]{};
    DWORD length = static_cast<DWORD>(std::size(buffer));
    if (GetComputerNameW(buffer, &length) == 0 || length == 0) return "windows-host";
    int utf8Length = WideCharToMultiByte(CP_UTF8, 0, buffer, static_cast<int>(length), nullptr, 0, nullptr, nullptr);
    std::string name(static_cast<size_t>(utf8Length), '\0');
    WideCharToMultiByte(CP_UTF8, 0, buffer, static_cast<int>(length), name.data(), utf8Length, nullptr, nullptr);
    return "windows-" + name;
}

std::filesystem::path credentialPath() {
    wchar_t buffer[MAX_PATH]{};
    const DWORD length = GetEnvironmentVariableW(L"APPDATA", buffer, MAX_PATH);
    std::filesystem::path directory = length > 0 ? std::filesystem::path(buffer) : std::filesystem::temp_directory_path();
    directory /= L"SidecarBridge";
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    return directory / L"trusted-device.bin";
}

Bytes loadCredential() {
    std::ifstream file(credentialPath(), std::ios::binary);
    if (!file) return {};
    Bytes protectedData((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    if (protectedData.empty()) return {};
    DATA_BLOB input{static_cast<DWORD>(protectedData.size()), protectedData.data()};
    DATA_BLOB output{};
    if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, 0, &output)) return {};
    Bytes result(output.pbData, output.pbData + output.cbData);
    LocalFree(output.pbData);
    return result;
}

void saveCredential(const Bytes& credential) {
    DATA_BLOB input{static_cast<DWORD>(credential.size()), const_cast<BYTE*>(credential.data())};
    DATA_BLOB output{};
    if (!CryptProtectData(&input, L"SidecarBridge trusted iPad", nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) return;
    std::ofstream file(credentialPath(), std::ios::binary | std::ios::trunc);
    if (file) file.write(reinterpret_cast<const char*>(output.pbData), output.cbData);
    LocalFree(output.pbData);
}

std::string utf8FromWide(const std::wstring& value) {
    if (value.empty()) return {};
    const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
                                           nullptr, 0, nullptr, nullptr);
    if (length <= 0) return {};
    std::string result(static_cast<size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
                        result.data(), length, nullptr, nullptr);
    return result;
}

std::wstring wideFromUtf8(const std::string& value) {
    if (value.empty()) return {};
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (length <= 0) return {};
    std::wstring result(static_cast<size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length);
    return result;
}

bool writeClipboardText(const std::string& value) {
    const std::wstring wide = wideFromUtf8(truncateUtf8(value, kMaximumClipboardBytes));
    if (wide.empty() && !value.empty()) return false;
    if (!OpenClipboard(nullptr)) return false;
    if (!EmptyClipboard()) {
        CloseClipboard();
        return false;
    }

    const SIZE_T bytes = (wide.size() + 1) * sizeof(wchar_t);
    HGLOBAL storage = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!storage) {
        CloseClipboard();
        return false;
    }
    void* destination = GlobalLock(storage);
    if (!destination) {
        GlobalFree(storage);
        CloseClipboard();
        return false;
    }
    std::memcpy(destination, wide.c_str(), bytes);
    GlobalUnlock(storage);
    if (SetClipboardData(CF_UNICODETEXT, storage) == nullptr) {
        GlobalFree(storage);
        CloseClipboard();
        return false;
    }
    // The clipboard owns `storage` after SetClipboardData succeeds.
    CloseClipboard();
    return true;
}

std::string readClipboardText() {
    if (!OpenClipboard(nullptr)) return {};
    HANDLE handle = GetClipboardData(CF_UNICODETEXT);
    if (!handle) {
        CloseClipboard();
        return {};
    }
    const auto* value = static_cast<const wchar_t*>(GlobalLock(handle));
    if (!value) {
        CloseClipboard();
        return {};
    }
    const std::wstring wide(value);
    GlobalUnlock(handle);
    CloseClipboard();
    return truncateUtf8(utf8FromWide(wide), kMaximumClipboardBytes);
}

Bytes captureJpeg() {
    const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (width <= 0 || height <= 0) return {};
    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
    if (memory && bitmap) SelectObject(memory, bitmap);
    if (!screen || !memory || !bitmap ||
        !BitBlt(memory, 0, 0, width, height, screen, left, top, SRCCOPY | CAPTUREBLT)) {
        if (bitmap) DeleteObject(bitmap);
        if (memory) DeleteDC(memory);
        if (screen) ReleaseDC(nullptr, screen);
        return {};
    }
    IWICImagingFactory* factory = nullptr;
    IWICBitmap* wicBitmap = nullptr;
    IWICStream* stream = nullptr;
    IStream* memoryStream = SHCreateMemStream(nullptr, 0);
    Bytes result;
    if (memoryStream && SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory2, nullptr, CLSCTX_INPROC_SERVER,
                                                   IID_PPV_ARGS(&factory))) &&
        SUCCEEDED(factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapUseBGRA, &wicBitmap)) &&
        SUCCEEDED(factory->CreateStream(&stream)) && SUCCEEDED(stream->InitializeFromIStream(memoryStream))) {
        IWICBitmapEncoder* encoder = nullptr;
        IWICBitmapFrameEncode* frame = nullptr;
        if (SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder)) &&
            SUCCEEDED(encoder->Initialize(stream, WICBitmapEncoderNoCache)) &&
            SUCCEEDED(encoder->CreateNewFrame(&frame, nullptr)) &&
            SUCCEEDED(frame->Initialize(nullptr)) && SUCCEEDED(frame->SetSize(static_cast<UINT>(width), static_cast<UINT>(height))) &&
            SUCCEEDED(frame->SetPixelFormat(const_cast<WICPixelFormatGUID*>(&GUID_WICPixelFormat32bppBGRA))) &&
            SUCCEEDED(frame->WriteSource(wicBitmap, nullptr)) && SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit())) {
            STATSTG stat{};
            if (SUCCEEDED(memoryStream->Stat(&stat, STATFLAG_NONAME)) && stat.cbSize.QuadPart > 0 && stat.cbSize.QuadPart <= kMaximumPayload) {
                LARGE_INTEGER zero{};
                memoryStream->Seek(zero, STREAM_SEEK_SET, nullptr);
                result.resize(static_cast<size_t>(stat.cbSize.QuadPart));
                ULONG read = 0;
                if (FAILED(memoryStream->Read(result.data(), static_cast<ULONG>(result.size()), &read)) || read != result.size()) result.clear();
            }
        }
        if (frame) frame->Release();
        if (encoder) encoder->Release();
    }
    if (stream) stream->Release();
    if (wicBitmap) wicBitmap->Release();
    if (factory) factory->Release();
    if (memoryStream) memoryStream->Release();
    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
    return result;
}

WORD virtualKeyForHID(int usage) {
    if (usage >= 0x04 && usage <= 0x1D) return static_cast<WORD>('A' + usage - 0x04);
    if (usage >= 0x1E && usage <= 0x27) return static_cast<WORD>('1' + usage - 0x1E);
    static const std::map<int, WORD> table = {
        {0x28, VK_RETURN}, {0x29, VK_ESCAPE}, {0x2A, VK_BACK}, {0x2B, VK_TAB}, {0x2C, VK_SPACE},
        {0x2D, VK_OEM_MINUS}, {0x2E, VK_OEM_PLUS}, {0x2F, VK_OEM_4}, {0x30, VK_OEM_6},
        {0x31, VK_OEM_5}, {0x33, VK_OEM_1}, {0x34, VK_OEM_7}, {0x35, VK_OEM_3},
        {0x36, VK_OEM_COMMA}, {0x37, VK_OEM_PERIOD}, {0x38, VK_OEM_2}, {0x39, VK_CAPITAL},
        {0x3A, VK_F1}, {0x3B, VK_F2}, {0x3C, VK_F3}, {0x3D, VK_F4}, {0x3E, VK_F5}, {0x3F, VK_F6},
        {0x40, VK_F7}, {0x41, VK_F8}, {0x42, VK_F9}, {0x43, VK_F10}, {0x44, VK_F11}, {0x45, VK_F12},
        {0x4F, VK_RIGHT}, {0x50, VK_LEFT}, {0x51, VK_DOWN}, {0x52, VK_UP}, {0x49, VK_INSERT},
        {0x4A, VK_HOME}, {0x4B, VK_PRIOR}, {0x4E, VK_END}, {0x4D, VK_NEXT}, {0x4C, VK_DELETE}
    };
    auto found = table.find(usage);
    return found == table.end() ? 0 : found->second;
}

DWORD modifierFlag(const std::string& modifier) {
    if (modifier == "command" || modifier == "meta" || modifier == "win" || modifier == "windows") return VK_LWIN;
    if (modifier == "control" || modifier == "ctrl") return VK_CONTROL;
    if (modifier == "option" || modifier == "alt") return VK_MENU;
    if (modifier == "shift") return VK_SHIFT;
    return 0;
}

void sendKey(WORD key, DWORD flags = 0) {
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = key;
    input.ki.dwFlags = flags;
    SendInput(1, &input, sizeof(input));
}

std::vector<WORD> pressModifierKeys(const std::string& inputJson) {
    // RemoteInputEvent.modifiers is a JSON array, so searching the whole
    // message for a quoted string is not sufficient (and was why modifier
    // shortcuts silently became plain key presses in the Windows prototype).
    const std::pair<const char*, WORD> values[] = {
        {"control", VK_CONTROL},
        {"shift", VK_SHIFT},
        {"option", VK_MENU},
        {"alt", VK_MENU},
        {"command", VK_LWIN},
        {"meta", VK_LWIN}
    };
    std::vector<WORD> held;
    for (const auto& value : values) {
        if (!jsonArrayContains(inputJson, "modifiers", value.first) ||
            std::find(held.begin(), held.end(), value.second) != held.end()) {
            continue;
        }
        sendKey(value.second);
        held.push_back(value.second);
    }
    return held;
}

void releaseModifierKeys(const std::vector<WORD>& held) {
    for (auto it = held.rbegin(); it != held.rend(); ++it) {
        sendKey(*it, KEYEVENTF_KEYUP);
    }
}

// A drag can arrive as primaryDown -> primaryDrag* -> primaryUp.  Keep the
// modifiers pressed for that whole sequence so Shift-drag and Option-drag
// retain their native Windows semantics instead of degrading to a plain drag.
std::mutex pointerModifierMutex;
std::vector<WORD> activePointerModifiers;

void releaseActivePointerModifiers() {
    std::vector<WORD> held;
    {
        std::lock_guard lock(pointerModifierMutex);
        held.swap(activePointerModifiers);
    }
    releaseModifierKeys(held);
}

void executeInput(const std::string& inputJson) {
    const std::string kind = jsonString(inputJson, "kind");
    const bool hasX = jsonHasNumber(inputJson, "x");
    const bool hasY = jsonHasNumber(inputJson, "y");
    const double x = std::clamp(jsonNumber(inputJson, "x", 0.5), 0.0, 1.0);
    const double y = std::clamp(jsonNumber(inputJson, "y", 0.5), 0.0, 1.0);
    const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    auto moveAbsolute = [&] {
        INPUT event{};
        event.type = INPUT_MOUSE;
        event.mi.dx = static_cast<LONG>(std::round(x * 65535.0));
        event.mi.dy = static_cast<LONG>(std::round(y * 65535.0));
        event.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        SendInput(1, &event, sizeof(event));
        SetCursorPos(left + static_cast<int>(x * std::max(width - 1, 0)), top + static_cast<int>(y * std::max(height - 1, 0)));
    };
    if ((kind == "pointerMove" || kind == "primaryDown" || kind == "primaryDrag" || kind == "primaryUp" ||
         kind == "primaryClick" || kind == "primaryDoubleClick" || kind == "secondaryClick" || kind == "secondaryDoubleClick") &&
        hasX && hasY) {
        moveAbsolute();
    }
    if (kind == "pointerDelta") {
        INPUT event{};
        event.type = INPUT_MOUSE;
        event.mi.dx = static_cast<LONG>(jsonNumber(inputJson, "deltaX"));
        event.mi.dy = static_cast<LONG>(jsonNumber(inputJson, "deltaY"));
        event.mi.dwFlags = MOUSEEVENTF_MOVE;
        SendInput(1, &event, sizeof(event));
    } else if (kind == "primaryDown" || kind == "primaryClick" || kind == "primaryDoubleClick") {
        const std::vector<WORD> held = pressModifierKeys(inputJson);
        const int count = kind == "primaryDoubleClick" ? 2 : 1;
        for (int i = 0; i < count; ++i) {
            INPUT event{}; event.type = INPUT_MOUSE; event.mi.dwFlags = MOUSEEVENTF_LEFTDOWN; SendInput(1, &event, sizeof(event));
            if (kind != "primaryDown") { event.mi.dwFlags = MOUSEEVENTF_LEFTUP; SendInput(1, &event, sizeof(event)); }
        }
        if (kind == "primaryDown") {
            std::lock_guard lock(pointerModifierMutex);
            activePointerModifiers = held;
        } else {
            releaseModifierKeys(held);
        }
    } else if (kind == "primaryUp") {
        INPUT event{}; event.type = INPUT_MOUSE; event.mi.dwFlags = MOUSEEVENTF_LEFTUP; SendInput(1, &event, sizeof(event));
        releaseActivePointerModifiers();
    } else if (kind == "secondaryClick" || kind == "secondaryDoubleClick") {
        const std::vector<WORD> held = pressModifierKeys(inputJson);
        const int count = kind == "secondaryDoubleClick" ? 2 : 1;
        for (int i = 0; i < count; ++i) {
            INPUT event{}; event.type = INPUT_MOUSE; event.mi.dwFlags = MOUSEEVENTF_RIGHTDOWN; SendInput(1, &event, sizeof(event));
            event.mi.dwFlags = MOUSEEVENTF_RIGHTUP; SendInput(1, &event, sizeof(event));
        }
        releaseModifierKeys(held);
    } else if (kind == "releaseButtons") {
        INPUT event{}; event.type = INPUT_MOUSE; event.mi.dwFlags = MOUSEEVENTF_LEFTUP | MOUSEEVENTF_RIGHTUP; SendInput(1, &event, sizeof(event));
        releaseActivePointerModifiers();
    } else if (kind == "scroll") {
        INPUT event{}; event.type = INPUT_MOUSE;
        event.mi.mouseData = static_cast<DWORD>(std::clamp(jsonNumber(inputJson, "deltaY") * -120.0, -12000.0, 12000.0));
        event.mi.dwFlags = MOUSEEVENTF_WHEEL;
        SendInput(1, &event, sizeof(event));
        const double deltaX = jsonNumber(inputJson, "deltaX");
        if (std::abs(deltaX) > 0.01) { event.mi.mouseData = static_cast<DWORD>(std::clamp(deltaX * 120.0, -12000.0, 12000.0)); event.mi.dwFlags = MOUSEEVENTF_HWHEEL; SendInput(1, &event, sizeof(event)); }
    } else if (kind == "text") {
        for (wchar_t character : wideFromUtf8(jsonString(inputJson, "text"))) {
            INPUT event{}; event.type = INPUT_KEYBOARD; event.ki.wScan = character; event.ki.dwFlags = KEYEVENTF_UNICODE; SendInput(1, &event, sizeof(event));
            event.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP; SendInput(1, &event, sizeof(event));
        }
    } else if (kind == "key") {
        const int usage = static_cast<int>(jsonNumber(inputJson, "hidUsage", 0));
        WORD key = virtualKeyForHID(usage);
        if (!key) {
            std::string name = jsonString(inputJson, "key");
            std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) {
                return static_cast<char>(std::tolower(c));
            });
            if (name == "enter" || name == "return") key = VK_RETURN;
            else if (name == "backspace" || name == "delete") key = VK_BACK;
            else if (name == "tab") key = VK_TAB;
            else if (name == "escape" || name == "esc") key = VK_ESCAPE;
            else if (name == "arrowup" || name == "up") key = VK_UP;
            else if (name == "arrowdown" || name == "down") key = VK_DOWN;
            else if (name == "arrowleft" || name == "left") key = VK_LEFT;
            else if (name == "arrowright" || name == "right") key = VK_RIGHT;
        }
        if (key) {
            const std::vector<WORD> held = pressModifierKeys(inputJson);
            sendKey(key); sendKey(key, KEYEVENTF_KEYUP);
            releaseModifierKeys(held);
        }
    } else if (kind == "cycleInputMode" || kind == "toggleChineseEnglishInputMode") {
        // Windows exposes the input-source switch as Win+Space.  Keep this
        // mapping local to the host so the iPad's 中/英 key and control-space
        // shortcut work without sending an unsupported macOS key code.
        sendKey(VK_LWIN);
        sendKey(VK_SPACE);
        sendKey(VK_SPACE, KEYEVENTF_KEYUP);
        sendKey(VK_LWIN, KEYEVENTF_KEYUP);
    }
}

Bytes encryptedFrame(const Bytes& sendKeyBytes, uint64_t& sendCounter, const Bytes& packet) {
    const Bytes envelope = seal(sendKeyBytes, 2, sendCounter++, packet);
    if (envelope.empty()) return {};
    Bytes payload{kEncrypted};
    payload.insert(payload.end(), envelope.begin(), envelope.end());
    return payload;
}

std::string fileTransferDirectory() {
    wchar_t buffer[MAX_PATH]{};
    const DWORD length = GetEnvironmentVariableW(L"USERPROFILE", buffer, MAX_PATH);
    std::filesystem::path directory = length > 0 ? std::filesystem::path(buffer) : std::filesystem::temp_directory_path();
    directory /= L"Downloads"; directory /= L"SidecarBridge Transfers";
    std::error_code error; std::filesystem::create_directories(directory, error);
    return directory.string();
}

} // namespace

struct WindowsTransport::Session {
    struct TransferState {
        std::filesystem::path path;
        int64_t expectedSize = 0;
        int64_t offset = 0;
    };

    SOCKET socket = INVALID_SOCKET;
    std::mutex sendMutex;
    // Capture and control responses can be produced by different threads.
    // Serialize counter allocation so every encrypted record has a unique
    // nonce even when a clipboard response races a video frame.
    std::mutex counterMutex;
    Bytes sendKey;
    Bytes receiveKey;
    uint64_t sendCounter = 0;
    uint64_t highestReceivedCounter = UINT64_MAX;
    uint64_t receivedWindow = 0;
    std::atomic<bool> authenticated{false};
    std::atomic<bool> closed{false};
    std::atomic<bool> socketClosed{false};
    std::map<std::string, TransferState> transfers;

    Bytes encrypted(const Bytes& packet) {
        std::lock_guard lock(counterMutex);
        return encryptedFrame(sendKey, sendCounter, packet);
    }
};

WindowsTransport::WindowsTransport(EventHandler eventHandler)
    : eventHandler_(std::move(eventHandler)), pairingCode_(), macID_(computerID()) {
    Bytes random;
    randomBytes(random, 16);
    for (uint8_t value : random) pairingCode_ += static_cast<char>('0' + value % 10);
}

WindowsTransport::~WindowsTransport() { stop(); }

void WindowsTransport::start() {
    if (running_.exchange(true)) return;
    stopRequested_ = false;
    worker_ = std::thread(&WindowsTransport::run, this);
}

void WindowsTransport::stop() {
    if (!running_.exchange(false)) return;
    stopRequested_ = true;
    disconnect();
    const SOCKET discoverySocket = static_cast<SOCKET>(discoverySocket_.load());
    if (discoverySocket != 0 && discoverySocket != INVALID_SOCKET) shutdown(discoverySocket, SD_BOTH);
    if (worker_.joinable()) worker_.join();
    if (captureWorker_.joinable()) captureWorker_.join();
    if (discoveryWorker_.joinable()) discoveryWorker_.join();
    WSACleanup();
}

void WindowsTransport::disconnect() {
    std::shared_ptr<Session> session;
    { std::lock_guard lock(sessionMutex_); session = session_; session_.reset(); }
    if (session) {
        session->closed = true;
        if (!session->socketClosed.exchange(true)) {
            shutdown(session->socket, SD_BOTH);
            closesocket(session->socket);
        }
    }
}

std::string WindowsTransport::pairingCode() const { return formatCode(pairingCode_); }
std::string WindowsTransport::localAddress() const { return localAddress_; }

void WindowsTransport::emit(const std::string& json) const { if (eventHandler_) eventHandler_(json); }

void WindowsTransport::emitState(const char* state, const char* headline, const char* detail, bool connected) const {
    std::ostringstream output;
    output << "{\"type\":\"state\",\"state\":\"" << escapeJson(state)
           << "\",\"headline\":\"" << escapeJson(headline) << "\",\"detail\":\""
           << escapeJson(detail) << "\",\"connected\":" << (connected ? "true" : "false")
           << ",\"pairingRequired\":false,\"pairingCode\":\"" << pairingCode()
           << "\",\"localAddress\":\"" << escapeJson(localAddress_) << "\"}";
    emit(output.str());
}

void WindowsTransport::run() {
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        emitState("error", "Windows network unavailable", "Winsock could not be initialized.", false);
        return;
    }
    char hostname[256]{};
    if (gethostname(hostname, sizeof(hostname)) == 0) {
        addrinfo hints{}; hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
        addrinfo* addresses = nullptr;
        if (getaddrinfo(hostname, nullptr, &hints, &addresses) == 0) {
            for (addrinfo* address = addresses; address; address = address->ai_next) {
                char text[INET_ADDRSTRLEN]{};
                auto* sin = reinterpret_cast<sockaddr_in*>(address->ai_addr);
                if (inet_ntop(AF_INET, &sin->sin_addr, text, sizeof(text)) && std::strncmp(text, "127.", 4) != 0) { localAddress_ = text; break; }
            }
            freeaddrinfo(addresses);
        }
    }
    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) { emitState("error", "Listener unavailable", "Could not create TCP 45454.", false); return; }
    BOOL reuse = TRUE; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof(reuse));
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_ANY); address.sin_port = htons(45454);
    if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == SOCKET_ERROR || listen(listener, 1) == SOCKET_ERROR) {
        closesocket(listener); emitState("error", "Listener unavailable", "TCP 45454 is already in use or blocked by Windows Firewall.", false); return;
    }
    discoveryWorker_ = std::thread(&WindowsTransport::discoveryLoop, this);
    emitState("idle", "Waiting for iPad", "SidecarBridge is listening on TCP 45454. Open the iPad app and select this Windows device.", false);
    while (!stopRequested_) {
        fd_set set; FD_ZERO(&set); FD_SET(listener, &set); timeval timeout{1, 0};
        if (select(0, &set, nullptr, nullptr, &timeout) <= 0) continue;
        SOCKET client = accept(listener, nullptr, nullptr);
        if (client == INVALID_SOCKET) continue;
        bool busy = false; { std::lock_guard lock(sessionMutex_); busy = static_cast<bool>(session_); }
        if (busy) { closesocket(client); continue; }
        handleClient(static_cast<uintptr_t>(client));
    }
    closesocket(listener);
}

void WindowsTransport::discoveryLoop() {
    // Minimal DNS-SD responder for networks where the Windows Bonjour service
    // is not installed. NWBrowser on iPadOS asks for _sb-direct._tcp; replying
    // to that query keeps the Windows host visible without a third-party
    // daemon or a public relay.
    SOCKET socket = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket == INVALID_SOCKET) return;
    BOOL reuse = TRUE;
    setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof(reuse));
    sockaddr_in bindAddress{}; bindAddress.sin_family = AF_INET; bindAddress.sin_addr.s_addr = htonl(INADDR_ANY); bindAddress.sin_port = htons(5353);
    if (bind(socket, reinterpret_cast<sockaddr*>(&bindAddress), sizeof(bindAddress)) == SOCKET_ERROR) { closesocket(socket); return; }
    ip_mreq membership{}; inet_pton(AF_INET, "224.0.0.251", &membership.imr_multiaddr); membership.imr_interface.s_addr = htonl(INADDR_ANY);
    setsockopt(socket, IPPROTO_IP, IP_ADD_MEMBERSHIP, reinterpret_cast<const char*>(&membership), sizeof(membership));
    discoverySocket_ = static_cast<uintptr_t>(socket);
    const std::string instance = "SidecarBridge Windows";
    const std::string host = instance;
    while (!stopRequested_) {
        fd_set set; FD_ZERO(&set); FD_SET(socket, &set); timeval timeout{1, 0};
        if (select(0, &set, nullptr, nullptr, &timeout) <= 0) continue;
        std::array<uint8_t, 1500> buffer{}; sockaddr_in sender{}; int senderLength = sizeof(sender);
        const int length = recvfrom(socket, reinterpret_cast<char*>(buffer.data()), static_cast<int>(buffer.size()), 0,
                                    reinterpret_cast<sockaddr*>(&sender), &senderLength);
        if (length < 13) continue;
        const std::string packet(reinterpret_cast<char*>(buffer.data()), reinterpret_cast<char*>(buffer.data()) + length);
        if (packet.find("_sb-direct") == std::string::npos) continue;
        std::array<uint8_t, 2> queryID{buffer[0], buffer[1]};
        const Bytes response = makeMDNSResponse(queryID, localAddress_.empty() ? "127.0.0.1" : localAddress_, instance, host);
        sockaddr_in multicast{}; multicast.sin_family = AF_INET; multicast.sin_port = htons(5353); inet_pton(AF_INET, "224.0.0.251", &multicast.sin_addr);
        sendto(socket, reinterpret_cast<const char*>(response.data()), static_cast<int>(response.size()), 0,
               reinterpret_cast<sockaddr*>(&sender), senderLength);
        sendto(socket, reinterpret_cast<const char*>(response.data()), static_cast<int>(response.size()), 0,
               reinterpret_cast<sockaddr*>(&multicast), sizeof(multicast));
    }
    setsockopt(socket, IPPROTO_IP, IP_DROP_MEMBERSHIP, reinterpret_cast<const char*>(&membership), sizeof(membership));
    closesocket(socket);
    discoverySocket_ = 0;
}

void WindowsTransport::handleClient(uintptr_t rawSocket) {
    // A previous client may have left the bounded capture worker joinable.
    // Reclaim it before assigning the next session so reconnects never call
    // std::terminate through a still-joinable std::thread.
    if (captureWorker_.joinable() && captureWorker_.get_id() != std::this_thread::get_id()) {
        captureWorker_.join();
    }
    SOCKET socket = static_cast<SOCKET>(rawSocket);
    auto session = std::make_shared<Session>(); session->socket = socket;
    { std::lock_guard lock(sessionMutex_); session_ = session; }
    auto closeSession = [&] {
        session->closed = true;
        releaseActivePointerModifiers();
        if (!session->socketClosed.exchange(true)) {
            shutdown(socket, SD_BOTH);
            closesocket(socket);
        }
        std::lock_guard lock(sessionMutex_); if (session_ == session) session_.reset();
        emitState("idle", "Waiting for iPad", "The previous session ended. The listener remains ready.", false);
    };

    Bytes hello;
    if (!receiveFrame(socket, hello) || hello.empty() || hello[0] != kClientHello) { closeSession(); return; }
    const std::string clientName = jsonString(std::string(hello.begin() + 1, hello.end()), "deviceName");
    const std::string clientID = jsonString(std::string(hello.begin() + 1, hello.end()), "deviceID");
    const std::string clientKind = jsonString(std::string(hello.begin() + 1, hello.end()), "deviceKind");
    const Bytes clientPublic = base64Decode(jsonString(std::string(hello.begin() + 1, hello.end()), "publicKey"));
    if (clientName.empty() || clientID.empty() || clientKind.empty() || clientPublic.size() != 32) { closeSession(); return; }
    PKey privateKey = makeX25519Key(); const Bytes serverPublic = rawPublicKey(privateKey.get()); const Bytes nonce = [&] { Bytes value; randomBytes(value, 32); return value; }();
    if (!privateKey || serverPublic.size() != 32 || nonce.size() != 32) { closeSession(); return; }
    const Bytes secret = deriveSecret(privateKey.get(), clientPublic);
    Bytes salt(reinterpret_cast<const uint8_t*>(kHKDFContext), reinterpret_cast<const uint8_t*>(kHKDFContext) + sizeof(kHKDFContext) - 1);
    appendLengthPrefixed(salt, clientPublic); appendLengthPrefixed(salt, serverPublic);
    session->sendKey = hkdfSha256(secret, salt, "server-to-client");
    session->receiveKey = hkdfSha256(secret, salt, "client-to-server");
    if (session->sendKey.size() != 32 || session->receiveKey.size() != 32) { closeSession(); return; }
    std::ostringstream response;
    response << "{\"protocolVersion\":3,\"deviceName\":\"Windows SidecarBridge\",\"publicKey\":\""
             << base64Encode(serverPublic) << "\",\"macID\":\"" << escapeJson(macID_)
             << "\",\"authNonce\":\"" << base64Encode(nonce) << "\",\"requiresPairingCode\":"
             << (loadCredential().empty() ? "true" : "false") << "}";
    Bytes serverHello{kServerHello}; const std::string responseString = response.str(); serverHello.insert(serverHello.end(), responseString.begin(), responseString.end());
    if (!sendFrame(socket, serverHello, session->sendMutex)) { closeSession(); return; }
    emitState("pairing", "iPad found", "Verify the iPad with the displayed 16-digit code. The code is only needed once on this Windows device.", false);

    bool authenticated = false;
    Bytes savedCredential = loadCredential();
    auto sendControlMessage = [&](const std::string& kind, const std::string& detail) {
        std::ostringstream message;
        message << "{\"kind\":\"" << escapeJson(kind) << "\"";
        if (!detail.empty()) {
            message << ",\"detail\":\"" << escapeJson(truncateUtf8(detail, kMaximumClipboardBytes)) << "\"";
        }
        message << "}";
        const std::string encoded = message.str();
        Bytes packet{kControlPacket};
        packet.insert(packet.end(), encoded.begin(), encoded.end());
        const Bytes frame = session->encrypted(packet);
        return !frame.empty() && sendFrame(socket, frame, session->sendMutex);
    };
    auto sendFileMessage = [&](const std::string& kind, const std::string& transferID,
                               int64_t offset, const std::string& message = {},
                               const std::string& digest = {}) {
        std::ostringstream payload;
        payload << "{\"kind\":\"" << escapeJson(kind) << "\",\"transferID\":\""
                << escapeJson(transferID) << "\",\"offset\":" << offset;
        if (!message.empty()) payload << ",\"message\":\"" << escapeJson(message) << "\"";
        if (!digest.empty()) payload << ",\"sha256\":\"" << escapeJson(digest) << "\"";
        payload << "}";
        const std::string encoded = payload.str();
        Bytes packet{kFilePacket};
        packet.insert(packet.end(), encoded.begin(), encoded.end());
        const Bytes frame = session->encrypted(packet);
        return !frame.empty() && sendFrame(socket, frame, session->sendMutex);
    };
    while (!stopRequested_ && !session->closed && receiveFrame(socket, hello)) {
        if (hello.empty() || hello[0] != kEncrypted) { closeSession(); return; }
        const Bytes plain = openPacket(session->receiveKey, 1, Bytes(hello.begin() + 1, hello.end()), session->highestReceivedCounter, session->receivedWindow);
        if (plain.empty()) { closeSession(); return; }
        if (!authenticated) {
            if (plain[0] != kAuthenticationPacket) { closeSession(); return; }
            const std::string message(plain.begin() + 1, plain.end());
            if (jsonString(message, "kind") != "response" || jsonNumber(message, "protocolVersion") != 3) { closeSession(); return; }
            const std::string proofString = jsonString(message, "proof"); const Bytes proof = base64Decode(proofString);
            const Bytes binding = channelBinding(clientPublic, serverPublic);
            const Bytes transcript = pairingTranscript("client", clientID, clientName, clientKind, macID_, nonce, binding);
            const Bytes codeSecret(pairingCode_.begin(), pairingCode_.end());
            const bool credentialOK = !savedCredential.empty() && constantTimeEqual(proof, hmacSha256(savedCredential, transcript));
            const bool codeOK = constantTimeEqual(proof, hmacSha256(codeSecret, transcript));
            if (!credentialOK && !codeOK) {
                const std::string detail = "The pairing code or saved credential was rejected.";
                const std::string rejected = "{\"kind\":\"rejected\",\"protocolVersion\":3,\"detail\":\"" + detail + "\"}";
                Bytes packet{kAuthenticationPacket}; packet.insert(packet.end(), rejected.begin(), rejected.end());
                sendFrame(socket, session->encrypted(packet), session->sendMutex);
                closeSession(); return;
            }
            Bytes responseProof = hmacSha256(codeOK ? codeSecret : savedCredential,
                                              pairingTranscript("server", clientID, clientName, clientKind, macID_, nonce, binding));
            Bytes issued;
            if (codeOK) { randomBytes(issued, 32); saveCredential(issued); }
            std::ostringstream accepted;
            accepted << "{\"kind\":\"accepted\",\"protocolVersion\":3,\"proof\":\"" << base64Encode(responseProof) << "\"";
            if (!issued.empty()) accepted << ",\"credential\":\"" << base64Encode(issued) << "\"";
            accepted << ",\"detail\":\"Encrypted Windows host ready\"}";
            const std::string acceptedString = accepted.str(); Bytes packet{kAuthenticationPacket}; packet.insert(packet.end(), acceptedString.begin(), acceptedString.end());
            if (!sendFrame(socket, session->encrypted(packet), session->sendMutex)) { closeSession(); return; }
            authenticated = true; session->authenticated = true;
            emitState("connected", "Connected to iPad", "Encrypted Windows screen, pointer, keyboard, scroll, clipboard text, and file transfer are active.", true);
            captureWorker_ = std::thread(&WindowsTransport::captureLoop, this, session);
            continue;
        }
        if (plain[0] == kControlPacket) {
            const std::string control(plain.begin() + 1, plain.end());
            const std::string kind = jsonString(control, "kind");
            if (kind == "input") {
                executeInput(jsonString(control, "detail"));
            } else if (kind == "clipboardText") {
                const std::string text = jsonString(control, "detail");
                if (!writeClipboardText(text)) {
                    sendControlMessage("clipboardError", "Windows could not write the clipboard.");
                }
            } else if (kind == "requestClipboard") {
                const std::string text = readClipboardText();
                if (!sendControlMessage(text.empty() ? "clipboardError" : "clipboardText",
                                        text.empty() ? "Windows clipboard is empty or unavailable." : text)) {
                    closeSession();
                    return;
                }
            }
        } else if (plain[0] == kFilePacket) {
            const std::string transfer(plain.begin() + 1, plain.end());
            const std::string kind = jsonString(transfer, "kind");
            const std::string transferID = jsonString(transfer, "transferID");
            if (kind == "begin" && !transferID.empty()) {
                const std::string rawName = jsonString(transfer, "name");
                const std::filesystem::path safeName = std::filesystem::path(wideFromUtf8(rawName)).filename();
                const double declaredSize = jsonNumber(transfer, "totalSize", -1.0);
                if (safeName.empty() || safeName == std::filesystem::path(L".") ||
                    safeName == std::filesystem::path(L"..") || declaredSize < 0.0 ||
                    declaredSize > 512.0 * 1024.0 * 1024.0 || std::floor(declaredSize) != declaredSize) {
                    continue;
                }
                const std::filesystem::path directory = std::filesystem::path(fileTransferDirectory());
                std::filesystem::path path = directory / safeName;
                for (unsigned int suffix = 1; std::filesystem::exists(path); ++suffix) {
                    const std::filesystem::path stem = path.stem();
                    const std::filesystem::path extension = path.extension();
                    path = directory / (stem.wstring() + L" (" + std::to_wstring(suffix) + L")" + extension.wstring());
                }
                std::ofstream file(path, std::ios::binary | std::ios::trunc);
                if (!file) {
                    continue;
                }
                session->transfers[transferID] = {path, static_cast<int64_t>(declaredSize), 0};
                if (!sendFileMessage("acknowledgement", transferID, 0)) { closeSession(); return; }
            } else if (kind == "chunk" && session->transfers.count(transferID)) {
                const Bytes chunk = base64Decode(jsonString(transfer, "payload"));
                auto& state = session->transfers[transferID];
                const double offset = jsonNumber(transfer, "offset", -1.0);
                if (offset < 0.0 || std::floor(offset) != offset || static_cast<int64_t>(offset) != state.offset ||
                    chunk.size() > 48 * 1024 || state.offset + static_cast<int64_t>(chunk.size()) > state.expectedSize) {
                    continue;
                }
                std::fstream file(state.path, std::ios::binary | std::ios::in | std::ios::out);
                file.seekp(static_cast<std::streamoff>(state.offset));
                file.write(reinterpret_cast<const char*>(chunk.data()), static_cast<std::streamsize>(chunk.size()));
                if (!file) continue;
                state.offset += static_cast<int64_t>(chunk.size());
                if (!sendFileMessage("acknowledgement", transferID, state.offset)) { closeSession(); return; }
            } else if (kind == "complete") {
                auto found = session->transfers.find(transferID);
                if (found == session->transfers.end() || found->second.offset != found->second.expectedSize) {
                    continue;
                }
                const int64_t completedSize = found->second.expectedSize;
                const std::string digest = jsonString(transfer, "sha256");
                session->transfers.erase(transferID);
                if (!sendFileMessage("complete", transferID, completedSize, "saved", digest)) { closeSession(); return; }
                emit("{\"type\":\"transfer\",\"state\":\"complete\"}");
            }
        }
    }
    closeSession();
}

void WindowsTransport::captureLoop(std::shared_ptr<Session> session) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    auto nextFrame = std::chrono::steady_clock::now();
    while (running_ && !stopRequested_ && !session->closed && session->authenticated) {
        nextFrame += std::chrono::milliseconds(16);
        const Bytes jpeg = captureJpeg();
        if (!jpeg.empty()) {
            Bytes packet{kJpegPacket}; packet.insert(packet.end(), jpeg.begin(), jpeg.end());
            const Bytes frame = session->encrypted(packet);
            if (frame.empty() || !sendFrame(session->socket, frame, session->sendMutex)) { session->closed = true; break; }
        }
        std::this_thread::sleep_until(nextFrame);
    }
    CoUninitialize();
}
