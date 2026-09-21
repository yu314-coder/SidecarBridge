import Foundation

enum DisplayUpscalingPolicy {
    static let diagnosticInput = CGSize(width: 1920, height: 1080)
    static let diagnosticOutput = CGSize(width: 2560, height: 1440)

    static func shouldUpscale(
        enabled: Bool,
        supported: Bool,
        input: CGSize,
        output: CGSize
    ) -> Bool {
        enabled && supported
            && input.width > 0 && input.height > 0
            && output.width > input.width && output.height > input.height
    }

    /// Returns the active MetalFX output dimensions from the renderer status.
    /// The live header uses this to distinguish the received stream resolution
    /// from the pixels actually presented on the iPad display.
    static func activeOutputDescription(from status: String) -> String? {
        guard status.hasPrefix("Active"),
              let arrow = status.range(of: "→") else { return nil }
        let tail = status[arrow.upperBound...]
        let output = tail.split(separator: "•", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty else { return nil }
        return output
    }
}
