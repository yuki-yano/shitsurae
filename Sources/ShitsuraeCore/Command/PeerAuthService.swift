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

public struct PeerAllowedAdHocIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    public let codeDirectoryHash: Data

    public init(bundleIdentifier: String, codeDirectoryHash: Data) {
        self.bundleIdentifier = bundleIdentifier
        self.codeDirectoryHash = codeDirectoryHash
    }
}

public struct PeerIdentity: Equatable, Sendable {
    public let teamIdentifier: String?
    public let bundleIdentifier: String?
    public let executablePath: String?
    public let codeDirectoryHash: Data?
    public let signatureValid: Bool
    public let appleAnchored: Bool

    public init(
        teamIdentifier: String?,
        bundleIdentifier: String?,
        executablePath: String?,
        codeDirectoryHash: Data?,
        signatureValid: Bool,
        appleAnchored: Bool
    ) {
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.codeDirectoryHash = codeDirectoryHash
        self.signatureValid = signatureValid
        self.appleAnchored = appleAnchored
    }
}

/// Authorizes unix-socket peers: same UID *and* a code-signing identity on
/// the allowlist (ported from v1's XPCAuthService). Same-UID alone would let
/// any user process drive Shitsurae's Accessibility powers.
public final class PeerAuthService: Sendable {
    private let allowlist: [PeerAllowedIdentity]
    private let adHocAllowlist: [PeerAllowedAdHocIdentity]
    private let identityProvider: @Sendable (Int32) -> PeerIdentity?

    public init(
        allowlist: [PeerAllowedIdentity] = PeerAuthService.defaultAllowlist(),
        adHocAllowlist: [PeerAllowedAdHocIdentity] = PeerAuthService.defaultAdHocAllowlist(),
        identityProvider: @escaping @Sendable (Int32) -> PeerIdentity? = PeerAuthService.identityForSocketPeer(fd:)
    ) {
        self.allowlist = allowlist
        self.adHocAllowlist = adHocAllowlist
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
        guard identity.signatureValid else { return false }
        guard let team = identity.teamIdentifier,
              let bundle = identity.bundleIdentifier
        else {
            guard identity.teamIdentifier == nil,
                  let bundle = identity.bundleIdentifier,
                  let codeDirectoryHash = identity.codeDirectoryHash
            else {
                return false
            }
            return adHocAllowlist.contains {
                $0.bundleIdentifier == bundle
                    && $0.codeDirectoryHash == codeDirectoryHash
            }
        }

        guard identity.appleAnchored else { return false }
        return allowlist.contains(where: { $0.teamIdentifier == team && $0.bundleIdentifier == bundle })
    }

    public static func defaultAllowlist() -> [PeerAllowedIdentity] {
        let team = currentExecutableIdentity()?.teamIdentifier
            ?? ProcessInfo.processInfo.environment["SHITSURAE_DEVELOPMENT_TEAM"]
            ?? "DEVELOPMENT_TEAM_UNSET"
        return [
            PeerAllowedIdentity(teamIdentifier: team, bundleIdentifier: "com.yuki-yano.shitsurae"),
            PeerAllowedIdentity(teamIdentifier: team, bundleIdentifier: "com.yuki-yano.shitsurae.cli"),
        ]
    }

    public static func defaultAdHocAllowlist() -> [PeerAllowedAdHocIdentity] {
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("shitsurae"),
              let identity = identityForExecutable(at: resourceURL),
              identity.signatureValid,
              identity.teamIdentifier == nil,
              let bundleIdentifier = identity.bundleIdentifier,
              let codeDirectoryHash = identity.codeDirectoryHash
        else {
            return []
        }
        return [PeerAllowedAdHocIdentity(
            bundleIdentifier: bundleIdentifier,
            codeDirectoryHash: codeDirectoryHash
        )]
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

        let signatureValid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        let appleAnchored = appleAnchorRequirement.map {
            SecCodeCheckValidity(code, [], $0) == errSecSuccess
        } ?? false
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        return identity(
            from: staticCode,
            signatureValid: signatureValid,
            appleAnchored: appleAnchored
        )
    }

    private static func currentExecutableIdentity() -> PeerIdentity? {
        identityForExecutable(at: Bundle.main.executableURL)
    }

    private static func identityForExecutable(at executableURL: URL?) -> PeerIdentity? {
        guard let executableURL else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
            let staticCode
        else {
            return nil
        }
        let signatureValid = SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
        let appleAnchored = appleAnchorRequirement.map {
            SecStaticCodeCheckValidity(staticCode, [], $0) == errSecSuccess
        } ?? false
        return identity(
            from: staticCode,
            signatureValid: signatureValid,
            appleAnchored: appleAnchored
        )
    }

    private static func identity(
        from staticCode: SecStaticCode,
        signatureValid: Bool,
        appleAnchored: Bool
    ) -> PeerIdentity? {
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
            executablePath: (info[kSecCodeInfoMainExecutable as String] as? URL)?.path,
            codeDirectoryHash: info[kSecCodeInfoUnique as String] as? Data,
            signatureValid: signatureValid,
            appleAnchored: appleAnchored
        )
    }

    private nonisolated(unsafe) static let appleAnchorRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "anchor apple generic" as CFString,
            [],
            &requirement
        ) == errSecSuccess else {
            return nil
        }
        return requirement
    }()
}
