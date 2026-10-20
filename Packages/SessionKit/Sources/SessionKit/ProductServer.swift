import Foundation

/// The one host the app's own server features talk to: server config, share links, Listening Maps,
/// attestation, anonymous tokens, the bridge manifest and the source catalog.
///
/// Debug builds accept a launch argument that swaps the host, so the Test Desk can run the offline check
/// (#1842) with the product server unreachable and nobody at the Mac (#2058):
///
///     xcrun simctl launch <udid> com.spokenmargins.native -SMServerHost offline.invalid
///
/// `.invalid` never resolves (RFC 6761), so every request fails as a network error, the way a down server
/// does, while the https and pinned-host checks still pass. Release builds never read the argument: the
/// gate is `#if DEBUG`, set at build time, never a value from the network or the device.
public enum ProductServer {
    public static let productionHost = "spokenmargins.proximitytoprogress.com"
    public static let hostArgument = "-SMServerHost"

    /// The host in use: `productionHost` unless a Debug build was launched with `-SMServerHost <host>`.
    public static let host: String = resolveHost(arguments: ProcessInfo.processInfo.arguments)

    /// An https URL on `host` with an absolute `path`.
    public static func url(path: String) -> URL {
        url(host: host, path: path)
    }

    static func url(host: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        return components.url!
    }

    /// The override when the build is Debug and the value is a plain DNS host name; `productionHost` otherwise.
    static func resolveHost(arguments: [String], debugBuild: Bool = isDebugBuild) -> String {
        guard debugBuild,
              let index = arguments.lastIndex(of: hostArgument),
              arguments.indices.contains(index + 1) else { return productionHost }
        let candidate = arguments[index + 1].lowercased()
        return isPlainHostName(candidate) ? candidate : productionHost
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Letters, digits, hyphens and dots only, with no empty label: no scheme, port, path or user part.
    static func isPlainHostName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
            label.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d }
        }
    }
}
