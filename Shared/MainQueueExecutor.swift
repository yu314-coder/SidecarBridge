import Foundation

enum MainQueueExecutor {
    static func sync<Result>(_ operation: () -> Result) -> Result {
        if Thread.isMainThread {
            return operation()
        }
        return DispatchQueue.main.sync(execute: operation)
    }
}
