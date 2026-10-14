// Keeps native identifier checks and identity creation consistent with the hosted survey contract.
import Foundation

/// Stateless validation helpers shared by configuration, presentation, and saved-state storage.
enum Identifiers {
    /// The checks below use this to reject partial regex matches, including a trailing newline.
    static func matchesEntireString(_ value: String, pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression)
        else {
            return false
        }

        return range.lowerBound == value.startIndex && range.upperBound == value.endIndex
    }

    /// Saved-state validation calls this before accepting a session ID that may later be restored.
    /// Keep the hosted identity alphabet so existing sessions (including UUIDs) resume unchanged.
    static func isValidSessionID(_ value: String) -> Bool {
        matchesEntireString(value, pattern: "^[A-Za-z0-9_-]{1,128}$")
    }

    /// Storage and saved-state validation use this to require the hosted contract's ULID format.
    static func isValidVisitorID(_ value: String) -> Bool {
        matchesEntireString(value, pattern: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$")
    }

    /// Public requests, provider results, and saved state must identify an organization/survey pair.
    static func isValidSurveySlug(_ value: String) -> Bool {
        matchesEntireString(value, pattern: "^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$")
    }

    /// StateStore allocates visitors and new sessions with a 48-bit timestamp and 80 random bits.
    static func makeULID(now: Int64) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var timestampMilliseconds = UInt64(min(max(0, now), 0xFFFF_FFFF_FFFF))
        var prefix = Array(repeating: Character("0"), count: 10)
        for index in (0 ..< 10).reversed() {
            prefix[index] = alphabet[Int(timestampMilliseconds & 31)]
            timestampMilliseconds >>= 5
        }
        return String(prefix) + String((0 ..< 16).map { _ in alphabet[Int.random(in: 0 ..< 32)] })
    }
}
