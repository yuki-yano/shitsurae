import Darwin
import Foundation
import Security

public struct PeerAllowedIdentity: Equatable, Sendable {
    public let teamIdentifier: String
    public let bundleIdentifier: String

    public init(teamIdentifier: String, bundleIdentifier: String) {
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct PeerIdentity: Equatable, Sendable {
    public let teamIdentifier: String?
    public let bundleIdentifier: String?
    public let executablePath: String?

    public init(teamIdentifier: String?, bundleIdentifier: String?, executablePath: String?) {
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }
}

/// Authorizes unix-socket peers: same UID *and* a code-signing identity on
/// the allowlist (ported from v1's XPCAuthService). Same-UID alone would let
/// any user process drive Shitsurae's Accessibility powers.
public final class PeerAuthService: Sendable {
    private let allowlist: [PeerAllowedIdentity]
    private let identityProvider: @Sendable (Int32) -> PeerIdentity?

    public init(
        allowlist: [PeerAllowedIdentity] = PeerAuthService.defaultAllowlist(),
        identityProvider: @escaping @Sendable (Int32) -> PeerIdentity? = PeerAuthService.identityForSocketPeer(fd:)
    ) {
        self.allowlist = allowlist
        self.identityProvider = identityProvider
    }

    public func authorize(fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            return false
        }

        guard let identity = identityProvider(fd) else {
            return false
        }
        return authorize(identity: identity)
    }

    func authorize(identity: PeerIdentity) -> Bool {
        guard let team = identity.teamIdentifier,
              let bundle = identity.bundleIdentifier
        else {
            return matchesAdHocDevelopmentIdentity(identity)
        }

        return allowlist.contains(where: { $0.teamIdentifier == team && $0.bundleIdentifier == bundle })
    }

    public static func defaultAllowlist() -> [PeerAllowedIdentity] {
        let team = ProcessInfo.processInfo.environment["SHITSURAE_DEVELOPMENT_TEAM"] ?? "DEVELOPMENT_TEAM_UNSET"
        return [
            PeerAllowedIdentity(teamIdentifier: team, bundleIdentifier: "com.yuki-yano.shitsurae"),
            PeerAllowedIdentity(teamIdentifier: team, bundleIdentifier: "com.yuki-yano.shitsurae.cli"),
        ]
    }

    /// Resolves the peer's code-signing identity from its audit token
    /// (LOCAL_PEERTOKEN) — pid-based lookup is racy; the audit token is not.
    public static func identityForSocketPeer(fd: Int32) -> PeerIdentity? {
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0 else {
            return nil
        }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        ) == errSecSuccess,
            let info = rawInfo as? [String: Any]
        else {
            return nil
        }

        return PeerIdentity(
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            bundleIdentifier: info[kSecCodeInfoIdentifier as String] as? String,
            executablePath: (info[kSecCodeInfoMainExecutable as String] as? URL)?.path
        )
    }

    /// Local ad-hoc builds carry no team identifier; allow the known
    /// Shitsurae executables (same policy as v1).
    private func matchesAdHocDevelopmentIdentity(_ identity: PeerIdentity) -> Bool {
        guard identity.teamIdentifier == nil else {
            return false
        }

        let allowedPrefixes = ["shitsurae-", "Shitsurae-", "com.yuki-yano.shitsurae"]
        if let bundle = identity.bundleIdentifier,
           allowedPrefixes.contains(where: { bundle.hasPrefix($0) })
        {
            return true
        }

        if let executablePath = identity.executablePath {
            let executable = URL(fileURLWithPath: executablePath).lastPathComponent
            return executable == "shitsurae" || executable == "shitsurae-cli" || executable == "Shitsurae"
        }

        return false
    }
}
