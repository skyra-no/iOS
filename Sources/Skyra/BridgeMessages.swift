// Defines the JSON exchanged between native code and the hosted survey page.
// Presentation builds Initialization; Bridge decodes BridgeMessage when WebKit delivers a message.
import Foundation

/// Used by JSON and saved-state validation when data cannot satisfy the hosted contract.
enum ContractError: Error {
    case invalid
}

/// One native-to-page snapshot, passed to JavaScript initialize before survey rendering starts.
struct Initialization: Encodable {
    private static let maximumEncodedBytes = 64 * 1024
    private static let supportedTextScale = 1.0 ... 3.0

    let version = 1
    let visitorId: String
    let sessionId: String
    let language: String?
    let device: String
    let traits: [String: String]
    let savedState: SkyraSavedState?
    var textScale: Double? = nil

    /// The names expected by the hosted page; they are protocol fields rather than Swift-only names.
    enum CodingKeys: String, CodingKey {
        case version
        case visitorId
        case sessionId
        case language
        case device
        case traits
        case savedState
        case textScale
    }

    /// JSONEncoder calls this to include explicit null savedState and validate optional text scaling.
    /// Explicit null prevents the page from silently falling back to its own browser storage.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(visitorId, forKey: .visitorId)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(device, forKey: .device)
        try container.encode(traits, forKey: .traits)
        // Explicit null disables the page's localStorage fallback.
        try container.encode(savedState, forKey: .savedState)
        if let textScale {
            guard
                textScale.isFinite,
                Self.supportedTextScale.contains(textScale)
            else {
                throw ContractError.invalid
            }

            try container.encode(textScale, forKey: .textScale)
        }
    }

    /// Presentation calls this to produce bounded JSON passed as a JavaScript argument, not source code.
    func json() throws -> String {
        let data = try JSONEncoder().encode(self)
        if data.count > Self.maximumEncodedBytes {
            throw ContractError.invalid
        }

        return String(decoding: data, as: UTF8.self)
    }
}

/// One page-to-native message. Bridge checks its identity and interprets its type after decoding.
struct BridgeMessage: Decodable {
    static let supportedVersion = 1

    let version: Int
    let type: String
    let presentationId: String
    let slug: String
    let surveyId: String?
    let visitorId: String?
    let sessionId: String?
    let state: SkyraSavedState?
    let code: String?
    let recoverable: Bool?
    let layout: PopupLayout?
}
