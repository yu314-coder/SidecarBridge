import Darwin
import Foundation

#if os(iOS)
import UIKit
#endif

struct SystemInformation: Codable, Equatable {
    let platform: String
    let operatingSystem: String
    let deviceModel: String
    let architecture: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let availableStorageBytes: Int64
    let totalStorageBytes: Int64
    let thermalState: String
    let lowPowerModeEnabled: Bool
    let appVersion: String
    let appBuild: String
    let systemUptimeSeconds: TimeInterval
    let collectedAt: Date

    var isValidForDisplay: Bool {
        let strings = [
            platform,
            operatingSystem,
            deviceModel,
            architecture,
            thermalState,
            appVersion,
            appBuild
        ]
        return strings.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
            && (1...1_024).contains(processorCount)
            && physicalMemoryBytes > 0
            && availableStorageBytes >= 0
            && totalStorageBytes >= availableStorageBytes
            && systemUptimeSeconds >= 0
    }

    static func current(
        processInfo: ProcessInfo = .processInfo,
        bundle: Bundle = .main,
        now: Date = Date()
    ) -> SystemInformation {
        let storage = storageCapacity()
        return SystemInformation(
            platform: platformName,
            operatingSystem: processInfo.operatingSystemVersionString,
            deviceModel: deviceModelName,
            architecture: architectureName,
            processorCount: max(1, processInfo.activeProcessorCount),
            physicalMemoryBytes: processInfo.physicalMemory,
            availableStorageBytes: storage.available,
            totalStorageBytes: storage.total,
            thermalState: thermalStateName(processInfo.thermalState),
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development",
            systemUptimeSeconds: max(0, processInfo.systemUptime),
            collectedAt: now
        )
    }

    var summaryRows: [DiagnosticField] {
        [
            DiagnosticField("Platform", platform),
            DiagnosticField("Operating system", operatingSystem),
            DiagnosticField("Model", deviceModel),
            DiagnosticField("Architecture", architecture),
            DiagnosticField("CPU", "\(processorCount) active cores"),
            DiagnosticField("Memory", Self.bytes(physicalMemoryBytes)),
            DiagnosticField(
                "Storage",
                "\(Self.bytes(UInt64(availableStorageBytes))) available of \(Self.bytes(UInt64(totalStorageBytes)))"
            ),
            DiagnosticField("Thermal state", thermalState),
            DiagnosticField("Low Power Mode", lowPowerModeEnabled ? "Enabled" : "Disabled"),
            DiagnosticField("App", "\(appVersion) (\(appBuild))"),
            DiagnosticField("System uptime", Self.duration(systemUptimeSeconds))
        ]
    }

    private static var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "iPadOS"
        case .phone: return "iOS"
        default: return "iOS/iPadOS"
        }
        #else
        return "Apple platform"
        #endif
    }

    private static var deviceModelName: String {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return machineIdentifier
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            return machineIdentifier
        }
        return String(cString: bytes)
        #elseif os(iOS)
        let identifier = machineIdentifier
        return identifier == "Unknown" ? UIDevice.current.model : identifier
        #else
        return machineIdentifier
        #endif
    }

    private static var machineIdentifier: String {
        var value = utsname()
        guard uname(&value) == 0 else { return "Unknown" }
        return withUnsafeBytes(of: &value.machine) { rawBuffer in
            let bytes = rawBuffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return machineIdentifier
        #endif
    }

    private static func storageCapacity() -> (available: Int64, total: Int64) {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let values = try? root.resourceValues(forKeys: keys) else {
            return (0, 0)
        }
        let available = max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = max(available, Int64(values.volumeTotalCapacity ?? 0))
        return (available, total)
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds) / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

struct DiagnosticField: Equatable {
    let name: String
    let value: String

    init(_ name: String, _ value: String) {
        self.name = Self.sanitize(name)
        self.value = Self.sanitize(value)
    }

    private static func sanitize(_ value: String) -> String {
        String(
            value
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .prefix(512)
        )
    }
}

enum DiagnosticReportBuilder {
    static func make(
        local: SystemInformation,
        remote: SystemInformation?,
        connection: [DiagnosticField],
        generatedAt: Date = Date()
    ) -> String {
        var sections = [
            "SidecarBridge Diagnostic Report",
            "Generated: \(ISO8601DateFormatter().string(from: generatedAt))",
            "Privacy: excludes pairing codes, credentials, device IDs, IP addresses, and file paths.",
            "",
            section("This Device", fields: local.summaryRows)
        ]
        if let remote, remote.isValidForDisplay {
            sections.append("")
            sections.append(section("Connected Device", fields: remote.summaryRows))
        }
        sections.append("")
        sections.append(section("Connection", fields: connection))
        return sections.joined(separator: "\n")
    }

    private static func section(_ title: String, fields: [DiagnosticField]) -> String {
        let safeFields = fields.filter { field in
            let key = field.name.lowercased()
            return ![
                "pairing",
                "credential",
                "device id",
                "device identifier",
                "ip address",
                "file path"
            ].contains(where: key.contains)
        }
        return (["[\(title)]"] + safeFields.map { "\($0.name): \($0.value)" })
            .joined(separator: "\n")
    }
}

extension ControlMessage {
    static var requestSystemInformation: ControlMessage {
        ControlMessage(.requestSystemInformation)
    }

    static func systemInformation(_ information: SystemInformation) -> ControlMessage? {
        guard information.isValidForDisplay,
              let data = try? JSONEncoder().encode(information),
              data.count <= 16 * 1_024,
              let json = String(data: data, encoding: .utf8) else { return nil }
        return ControlMessage(.systemInformation, detail: json)
    }

    var systemInformationPayload: SystemInformation? {
        guard kind == .systemInformation,
              let detail,
              detail.utf8.count <= 16 * 1_024,
              let data = detail.data(using: .utf8),
              let information = try? JSONDecoder().decode(SystemInformation.self, from: data),
              information.isValidForDisplay else { return nil }
        return information
    }
}
