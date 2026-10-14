// Central service addresses used by configuration; individual integrations can override them.
import Foundation

/// Service defaults for Skyra-hosted surveys. Keep endpoint changes in this file.
public enum SkyraDefaults {
    public static let hostedOrigin = URL(string: "https://survey.skyra.no")!

    /// Matches apps/survey/Dockerfile's production VITE_API_HOST in the web repository.
    public static let deliveryOrigin: URL? = URL(string: "https://ingest.skyra.no")!
}
