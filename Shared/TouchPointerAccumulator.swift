import Foundation

/// Preserve every relative movement sample when network emission is throttled.
/// Only direct finger input uses this accumulator, never indirect pointers.
struct TouchPointerAccumulator {
    private var x = 0.0
    private var y = 0.0
    mutating func add(x: Double, y: Double) {
        self.x += x
        self.y += y
    }
    mutating func take() -> (x: Double, y: Double) {
        defer { reset() }
        return (x, y)
    }
    mutating func reset() { x = 0; y = 0 }
}
