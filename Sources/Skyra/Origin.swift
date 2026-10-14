// Gives message validation and storage one definition of a website's scheme, host, and effective port.
import Foundation

/// Comparable website identity. Default ports normalize to the same value as explicit ports.
struct Origin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    /// Configuration, StateStore, and WebKit callbacks use this to normalize an HTTP(S) source URL.
    init?(_ url: URL) {
        guard
            let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased(),
            ["http", "https"].contains(scheme)
        else {
            return nil
        }

        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    /// StateStore uses this namespace so data from different hosted origins cannot mix.
    var key: String {
        "\(scheme)://\(host):\(port)"
    }
}
