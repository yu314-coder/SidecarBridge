cmake_minimum_required(VERSION 3.24)

project(SidecarBridgeWindows VERSION 0.1.0 LANGUAGES CXX)

if(NOT WIN32)
    message(WARNING "The Windows companion must be configured on Windows with the Win32 SDK.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(SIDECARBRIDGE_ENABLE_TRANSPORT "Build the encrypted iPad host transport" ON)

if(SIDECARBRIDGE_ENABLE_TRANSPORT)
    # OpenSSL supplies the portable X25519, HKDF, HMAC and ChaCha20-Poly1305
    # primitives used by the iPad/macOS v3 wire protocol.  It is linked only
    # into the native host; the WebView never receives crypto keys.
    find_package(OpenSSL 1.1.1 REQUIRED COMPONENTS Crypto)
endif()

# Point this at the extracted Microsoft.Web.WebView2 NuGet package. The
# package contains WebView2.h and the architecture-specific loader library.
set(WEBVIEW2_SDK_DIR "" CACHE PATH "Root of the Microsoft.Web.WebView2 SDK package")

if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(WEBVIEW2_ARCH x64)
else()
    set(WEBVIEW2_ARCH x86)
endif()

find_path(WEBVIEW2_INCLUDE_DIR
    NAMES WebView2.h
    HINTS
        "${WEBVIEW2_SDK_DIR}/build/native/include"
        "${WEBVIEW2_SDK_DIR}/build/native"
)

find_library(WEBVIEW2_LOADER_LIBRARY
    NAMES WebView2LoaderStatic WebView2Loader
    HINTS
        "${WEBVIEW2_SDK_DIR}/build/native/${WEBVIEW2_ARCH}"
        "${WEBVIEW2_SDK_DIR}/build/native/${WEBVIEW2_ARCH}/Microsoft.Web.WebView2.targets"
)

if(NOT WEBVIEW2_INCLUDE_DIR OR NOT WEBVIEW2_LOADER_LIBRARY)
    message(FATAL_ERROR
        "WebView2 SDK was not found. Configure with "
        "-DWEBVIEW2_SDK_DIR=<Microsoft.Web.WebView2 package>.")
endif()

add_executable(SidecarBridgeWindows WIN32
    src/main.cpp
    src/webview.cpp
    src/webview.h
    src/bridge_session.cpp
    src/bridge_session.h
)

if(SIDECARBRIDGE_ENABLE_TRANSPORT)
    target_sources(SidecarBridgeWindows PRIVATE
        src/bridge_transport.cpp
        src/bridge_transport.h
    )
endif()

target_include_directories(SidecarBridgeWindows PRIVATE
    "${WEBVIEW2_INCLUDE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

target_compile_definitions(SidecarBridgeWindows PRIVATE
    UNICODE
    _UNICODE
    NOMINMAX
    WIN32_LEAN_AND_MEAN
    _WIN32_WINNT=0x0A00
    SIDECARBRIDGE_WINDOWS_SHELL=1
)

if(SIDECARBRIDGE_ENABLE_TRANSPORT)
    target_compile_definitions(SidecarBridgeWindows PRIVATE SIDECARBRIDGE_WINDOWS_TRANSPORT=1)
endif()

target_link_libraries(SidecarBridgeWindows PRIVATE
    "${WEBVIEW2_LOADER_LIBRARY}"
    ole32
    oleaut32
    shlwapi
    shell32
    user32
    version
    ws2_32
    windowscodecs
    crypt32
)

if(SIDECARBRIDGE_ENABLE_TRANSPORT)
    target_link_libraries(SidecarBridgeWindows PRIVATE OpenSSL::Crypto)
endif()

if(MSVC)
    target_compile_options(SidecarBridgeWindows PRIVATE /W4 /permissive-)
else()
    target_compile_options(SidecarBridgeWindows PRIVATE -Wall -Wextra -Wpedantic)
endif()

set_target_properties(SidecarBridgeWindows PROPERTIES
    OUTPUT_NAME "SidecarBridgeWindows"
    VS_DEBUGGER_WORKING_DIRECTORY "$<TARGET_FILE_DIR:SidecarBridgeWindows>"
)

add_custom_command(TARGET SidecarBridgeWindows POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/web"
        "$<TARGET_FILE_DIR:SidecarBridgeWindows>/web"
    COMMENT "Copying SidecarBridge Windows web UI"
)
