// Central service address and SDK version; a configuration can override the address.
import Foundation

/// Service defaults for Skyra. Keep endpoint changes in this file.
public enum SkyraDefaults {
    /// Skyra's decision service. Matches VITE_DECISION_HOST in the web repository's apps/survey/Dockerfile.
    public static let decisionOrigin = URL(string: "https://ingest.skyra.no")!

    /// Sent with every decision request. A survey meant for the app has an audience rule on it.
    static let traits = ["channel": "app"]

    /// The released version, as tagged. Reported in the decision request's User-Agent and as `Skyra.version`.
    static let sdkVersion = "0.2.0"
}
