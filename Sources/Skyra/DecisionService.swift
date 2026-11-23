// Asks Skyra's decision service which inline surveys a visitor may see in the app.
// Request and response shapes follow the survey decision contract (version 1, POST /v1/decide).
import Foundation
import CoreFoundation
#if canImport(UIKit)
import UIKit
#endif

/// A survey the decision service allows for this visitor.
///
/// The decision names the survey; it does not contain its questions. The Skyra widget loads the
/// survey, runs its session and sends the answers.
public struct SkyraSurvey: Equatable, Hashable, Sendable {
    /// Full survey identifier in `organisation/survey` form.
    public let slug: String
    /// The language the service chose for the survey, such as `nb` or `en`.
    public let language: String

    public init(slug: String, language: String) {
        self.slug = slug
        self.language = language
    }
}

/// Everything a version 1 decision request tells the service about one visitor at one moment.
struct DecisionRequest: Equatable, Sendable {
    static let version = 1
    /// The contract rejects larger bodies, so the SDK refuses to send one rather than be rejected.
    static let maximumBodyBytes = 64 * 1024

    let organization: String
    let device: String
    let language: String?
    let locale: String?
    let timeZone: String
    let traits: [String: String]
    let state: SkyraState
    let userAgent: String

    /// Encodes the exact version 1 body for an inline request. An app has no page, so `url` is an
    /// explicit null. Optional keys are omitted rather than sent as null. Throws requestTooLarge when the body exceeds 64 KB.
    func encoded() throws -> Data {
        var body: [String: Any] = [
            "version": Self.version,
            "org": organization,
            "type": "inline",
            "url": NSNull(),
            "device": device,
            "timeZone": timeZone,
            "traits": traits,
            "skyraState": state.jsonObject(includingProgress: false),
        ]
        if let language {
            body["language"] = language
        }
        if let locale {
            body["locale"] = locale
        }

        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard data.count <= Self.maximumBodyBytes else {
            throw SkyraError.requestTooLarge
        }

        return data
    }
}

/// Client for POST {decisionOrigin}/v1/decide. Stateless: each call is one bounded, uncached request.
enum DecisionService {
    static let path = "/v1/decide"
    /// DEC-008: give up after 1.5 seconds and never retry.
    static let limits = BoundedTransport.Limits(
        requestTimeout: 1.5,
        resourceTimeout: 1.5,
        maximumResponseBytes: 2_097_152
    )

    /// Sends the request and returns every inline survey the service allows, in the service's order.
    static func decide(origin: URL, request: DecisionRequest) async throws -> [SkyraSurvey] {
        try Task.checkCancellation()
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = path
        var urlRequest = URLRequest(
            url: components.url!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: limits.requestTimeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try request.encoded()
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue(request.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, status) = try await BoundedTransport.load(urlRequest, limits: limits)
        try Task.checkCancellation()
        return try decode(data, status: status, organization: request.organization)
    }

    /// Decodes the version 1 answer independently of transport, so contract tests need no network.
    /// Every survey must belong to `organization` and name a language that passes the configuration's
    /// language check; one malformed entry makes the whole answer invalid.
    /// Fields this SDK does not know are ignored (DEC-009).
    static func decode(_ data: Data, status: Int, organization: String) throws -> [SkyraSurvey] {
        guard status == 200 else {
            throw SkyraError.decisionHTTPStatus(status)
        }
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            integer(root["version"]) == DecisionRequest.version,
            let inline = root["inline"] as? [Any]
        else {
            throw SkyraError.invalidDecisionResponse
        }

        return try inline.map { survey in
            guard
                let entry = survey as? [String: Any],
                let slug = entry["slug"] as? String,
                let language = entry["language"] as? String,
                Identifiers.isValidSurveySlug(slug),
                slug.hasPrefix(organization + "/"),
                SkyraConfiguration.isValidLanguage(language)
            else {
                throw SkyraError.invalidDecisionResponse
            }

            return SkyraSurvey(slug: slug, language: language)
        }
    }

    /// JSON booleans bridge to NSNumber, so reject them before accepting a numeric protocol field.
    private static func integer(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue == Double(number.intValue)
        else {
            return nil
        }

        return number.intValue
    }
}

/// What the request says about the device: its class for the body and its details for the User-Agent.
struct DecisionDevice: Equatable {
    /// `mobile` or `tablet`.
    let deviceClass: String
    let userAgent: String

    /// Reads the device and the host app's bundle. UIKit's device details live on the main actor.
    @MainActor
    static func current(bundle: Bundle = .main) -> DecisionDevice {
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleName"] as? String) ?? (info["CFBundleExecutable"] as? String)
        let version = info["CFBundleShortVersionString"] as? String
        #if canImport(UIKit)
        let device = UIDevice.current
        let deviceClass = device.userInterfaceIdiom == .pad ? "tablet" : "mobile"
        let systemName = device.systemName
        let systemVersion = device.systemVersion
        #else
        // Builds without UIKit run the portable tests on macOS.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let deviceClass = "mobile"
        let systemName = "macOS"
        let systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #endif
        return DecisionDevice(
            deviceClass: deviceClass,
            userAgent: DecisionUserAgent.make(
                sdkVersion: SkyraDefaults.sdkVersion,
                appName: name,
                appVersion: version,
                systemName: systemName,
                systemVersion: systemVersion
            )
        )
    }
}

/// Builds the descriptive User-Agent that contract DEC-011 requires from app clients.
enum DecisionUserAgent {
    /// Formats `Skyra-iOS/<sdk> (<app>/<version>; <os> <os version>)`. Missing values become "unknown".
    /// Pure, so tests can check the format without a bundle or device.
    static func make(
        sdkVersion: String,
        appName: String?,
        appVersion: String?,
        systemName: String,
        systemVersion: String
    ) -> String {
        let app = token(appName) + "/" + token(appVersion)
        return "Skyra-iOS/\(sdkVersion) (\(app); \(token(systemName)) \(token(systemVersion)))"
    }

    /// Trims a value, replaces characters that would break the header's structure, and falls back to "unknown".
    private static func token(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "unknown"
        }

        let safe = trimmed.unicodeScalars.map { scalar -> Character in
            let printable = (0x20 ... 0x7E).contains(scalar.value)
            let structural = ["(", ")", ";", "/"].contains(Character(scalar))
            return printable && !structural ? Character(scalar) : "_"
        }
        return String(safe)
    }
}
