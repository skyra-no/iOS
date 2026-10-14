// Shares the timestamp unit used by the hosted contract and native retention rules.
import Foundation

/// A namespace for the Date-to-milliseconds conversion; it holds no ticking clock or mutable state.
enum Clock {
    /// Storage and message validation call this for Unix time compatible with JavaScript Date.now().
    static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
