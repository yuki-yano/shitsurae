import Foundation
import Security

public struct XPCAllowedIdentity: Equatable, Sendable {
    public let teamIdentifier: String
    public let bundleIdentifier: String

    public init(teamIdentifier: String, bundleIdentifier: String) {
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct XPCClientIdentity: Equatable, Sendable {
    public let teamIdentifier: String?
    public let bundleIdentifier: String?
    public let executablePath: String?

    public init(teamIdentifier: String?, bundleIdentifier: String?, executablePath: String?) {
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }
}

public protocol XPCClientIdentityProviding {
    func identity(for pid: pid_t) -> XPCClientIdentity?
}

public struct SecurityCodeIdentityProvider: XPCClientIdentityProviding {
    public init() {}

    public func identity(for pid: pid_t) -> XPCClientIdentity? {
        let attributes: [CFString: Any] = [kSecGuestAttributePid: NSNumber(value: pid)]
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return nil
        }

        var rawInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo)
        guard infoStatus == errSecSuccess,
              let info = rawInfo as? [String: Any]
        else {
            return nil
        }

        let bundleIdentifier = info[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        let executableURL = info[kSecCodeInfoMainExecutable as String] as? URL
        return XPCClientIdentity(
            teamIdentifier: teamIdentifier,
            bundleIdentifier: bundleIdentifier,
            executablePath: executableURL?.path
        )
    }
}

public final class XPCAuthService {
    private let allowlist: [XPCAllowedIdentity]
    private let identityProvider: XPCClientIdentityProviding

    public init(
        allowlist: [XPCAllowedIdentity] = XPCAuthService.defaultAllowlist(),
        identityProvider: XPCClientIdentityProviding = SecurityCodeIdentityProvider()
    ) {
        self.allowlist = allowlist
        self.identityProvider = identityProvider
    }

    public func authorize(connection: NSXPCConnection) -> Bool {
        authorize(
            clientPID: connection.processIdentifier,
            clientUID: uid_t(connection.effectiveUserIdentifier),
            currentUID: getuid()
        )
    }

    public func authorize(clientPID: pid_t, clientUID: uid_t, currentUID: uid_t) -> Bool {
        guard clientUID == currentUID else {
            return false
        }

        guard let identity = identityProvider.identity(for: clientPID) else {
            return false
        }

        guard let team = identity.teamIdentifier,
              let bundle = identity.bundleIdentifier
        else {
            return matchesAdHocDevelopmentIdentity(identity)
        }

        return allowlist.contains(where: { $0.teamIdentifier == team && $0.bundleIdentifier == bundle })
    }

    public static func defaultAllowlist() -> [XPCAllowedIdentity] {
        let team = ProcessInfo.processInfo.environment["SHITSURAE_DEVELOPMENT_TEAM"] ?? "DEVELOPMENT_TEAM_UNSET"
        return [
            XPCAllowedIdentity(teamIdentifier: team, bundleIdentifier: "com.yuki-yano.shitsurae"),
            XPCAllowedIdentity(teamIdentifier: team, bundleIdentifier: "com.yuki-yano.shitsurae.cli"),
        ]
    }

    private func matchesAdHocDevelopmentIdentity(_ identity: XPCClientIdentity) -> Bool {
        guard identity.teamIdentifier == nil else {
            return false
        }

        let allowedPrefixes = [
            "shitsurae-",
            "Shitsurae-",
        ]

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
