// Keeps identifier checks and identity creation consistent with Skyra's decision and session contracts.
import Foundation

/// Stateless validation helpers shared by configuration, the state, and storage.
enum Identifiers {
    /// The checks below use this to reject partial regex matches, including a trailing newline.
    static func matchesEntireString(_ value: String, pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression)
        else {
            return false
        }

        return range.lowerBound == value.startIndex && range.upperBound == value.endIndex
    }

    /// A session ID is a ULID. The decision service refuses a request that carries any other.
    static func isValidSessionID(_ value: String) -> Bool {
        matchesEntireString(value, pattern: "^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{26}$")
    }

    /// The longest organisation, survey or trait name. The decision service refuses a longer one.
    static let maximumSlugLength = 100
    /// A name as Skyra writes it: letters, digits, `_` and `-`, starting with a letter or digit.
    private static let slug = "[A-Za-z0-9][A-Za-z0-9_-]{0,\(maximumSlugLength - 1)}"

    /// Organisations and trait names are slugs.
    static func isValidSlug(_ value: String) -> Bool {
        matchesEntireString(value, pattern: "^\(slug)$")
    }

    /// The decision contract requires the visitor ID to be a ULID. One whose time is zero was not
    /// made by a clock. It would count as created first in every sync, so it is refused.
    static func isValidVisitorID(_ value: String) -> Bool {
        matchesEntireString(value, pattern: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$")
            && !value.hasPrefix(timePrefix(0))
    }

    /// Whether a valid visitor ID was created at or before `time`, in Unix milliseconds.
    /// A ULID starts with its creation time, so comparing the text compares the times.
    static func isVisitorID(_ value: String, createdBy time: Int64) -> Bool {
        String(value.prefix(10)) <= timePrefix(time)
    }

    /// A survey is named by an organisation/survey pair of slugs.
    static func isValidSurveySlug(_ value: String) -> Bool {
        matchesEntireString(value, pattern: "^\(slug)/\(slug)$")
    }

    /// StateStore allocates the visitor with a 48-bit timestamp and 80 random bits.
    /// The time is at least one millisecond, so the ID is valid even on a clock that reads zero.
    static func makeULID(now: Int64) -> String {
        timePrefix(max(1, now))
            + String((0 ..< 16).map { _ in ulidAlphabet[Int.random(in: 0 ..< 32)] })
    }

    /// The ten characters a ULID created at `time` starts with.
    private static func timePrefix(_ time: Int64) -> String {
        var timestampMilliseconds = UInt64(min(max(0, time), 0xFFFF_FFFF_FFFF))
        var prefix = Array(repeating: Character("0"), count: 10)
        for index in (0 ..< 10).reversed() {
            prefix[index] = ulidAlphabet[Int(timestampMilliseconds & 31)]
            timestampMilliseconds >>= 5
        }
        return String(prefix)
    }

    private static let ulidAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
}
