// Shares the timestamp unit used by the decision contract and the retention rule.
import Foundation

/// A namespace for the Date-to-milliseconds conversion; it holds no ticking clock or mutable state.
enum Clock {
    /// Storage calls this for Unix time compatible with JavaScript Date.now().
    static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
