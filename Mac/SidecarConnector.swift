import AppKit
import Foundation

final class SidecarConnector {
    enum Transport: String {
        case wired
        case wireless
    }

    enum ConnectorError: LocalizedError {
        case frameworkUnavailable
        case managerUnavailable
        case noDevices
        case deviceNotFound(String)
        case configurationUnavailable

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable: return "The SidecarCore private framework is unavailable."
            case .managerUnavailable: return "The Sidecar display manager is unavailable."
            case .noDevices: return "No reachable Sidecar-capable iPad was found."
            case .deviceNotFound(let name): return "Sidecar could not find \(name)."
            case .configurationUnavailable: return "Wired Sidecar configuration is unavailable."
            }
        }
    }

    private let frameworkPath = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
    private var frameworkHandle: UnsafeMutableRawPointer?

    deinit {
        if let frameworkHandle { dlclose(frameworkHandle) }
    }

    func reachableDeviceNames() -> [String] {
        (try? devices().compactMap(deviceName)) ?? []
    }

    func connect(
        preferredName: String?,
        transport: Transport,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        do {
            let manager = try displayManager()
            let devices = try devices(manager: manager)
            guard !devices.isEmpty else { throw ConnectorError.noDevices }

            let device: NSObject
            if let preferredName, !preferredName.isEmpty {
                device = devices.first(where: {
                    guard let name = deviceName($0) else { return false }
                    return name.compare(preferredName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                        || name.localizedCaseInsensitiveContains(preferredName)
                        || preferredName.localizedCaseInsensitiveContains(name)
                }) ?? (devices.count == 1 ? devices[0] : devices[0])
            } else {
                device = devices[0]
            }
            let selectedName = deviceName(device) ?? preferredName ?? "iPad"

            let callback: @convention(block) (NSError?) -> Void = { error in
                DispatchQueue.main.async {
                    if let error { completion(.failure(error)) }
                    else { completion(.success(selectedName)) }
                }
            }

            switch transport {
            case .wireless:
                _ = manager.perform(
                    Selector(("connectToDevice:completion:")),
                    with: device,
                    with: callback
                )
            case .wired:
                guard let configType = NSClassFromString("SidecarDisplayConfig") as? NSObject.Type else {
                    throw ConnectorError.configurationUnavailable
                }
                let config = configType.init()
                let setTransportSelector = Selector(("setTransport:"))
                let implementation = config.method(for: setTransportSelector)
                let setTransport = unsafeBitCast(
                    implementation,
                    to: (@convention(c) (AnyObject, Selector, Int64) -> Void).self
                )
                setTransport(config, setTransportSelector, 2)

                let selector = Selector(("connectToDevice:withConfig:completion:"))
                let implementation2 = manager.method(for: selector)
                let connect = unsafeBitCast(
                    implementation2,
                    to: (@convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject) -> Void).self
                )
                connect(manager, selector, device, config, callback as AnyObject)
            }
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    private func loadFramework() throws {
        if frameworkHandle != nil { return }
        frameworkHandle = dlopen(frameworkPath, RTLD_LAZY)
        if frameworkHandle == nil { throw ConnectorError.frameworkUnavailable }
    }

    private func displayManager() throws -> NSObject {
        try loadFramework()
        guard let managerType = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              let manager = managerType.perform(Selector(("sharedManager")))?.takeUnretainedValue() as? NSObject else {
            throw ConnectorError.managerUnavailable
        }
        return manager
    }

    private func devices() throws -> [NSObject] {
        try devices(manager: displayManager())
    }

    private func devices(manager: NSObject) throws -> [NSObject] {
        guard let result = manager.perform(Selector(("devices")))?.takeUnretainedValue() as? [NSObject] else {
            throw ConnectorError.managerUnavailable
        }
        return result
    }

    private func deviceName(_ device: NSObject) -> String? {
        device.perform(Selector(("name")))?.takeUnretainedValue() as? String
    }
}
