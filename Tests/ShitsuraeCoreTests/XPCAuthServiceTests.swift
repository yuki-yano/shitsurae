import Darwin
import XCTest
@testable import ShitsuraeCore

final class XPCAuthServiceTests: XCTestCase {
    func testAuthorizeAllowsSameUserAndAllowlistedIdentity() {
        let provider = StubIdentityProvider(
            identities: [
                1001: XPCClientIdentity(
                    teamIdentifier: "TEAMID1234",
                    bundleIdentifier: "com.yuki-yano.shitsurae.cli",
                    executablePath: "/tmp/shitsurae"
                ),
            ]
        )

        let service = XPCAuthService(
            allowlist: [
                XPCAllowedIdentity(teamIdentifier: "TEAMID1234", bundleIdentifier: "com.yuki-yano.shitsurae.cli"),
            ],
            identityProvider: provider
        )

        XCTAssertTrue(service.authorize(clientPID: 1001, clientUID: 501, currentUID: 501))
    }

    func testAuthorizeRejectsDifferentUser() {
        let provider = StubIdentityProvider(
            identities: [
                1002: XPCClientIdentity(
                    teamIdentifier: "TEAMID1234",
                    bundleIdentifier: "com.yuki-yano.shitsurae.cli",
                    executablePath: "/tmp/shitsurae"
                ),
            ]
        )

        let service = XPCAuthService(
            allowlist: [
                XPCAllowedIdentity(teamIdentifier: "TEAMID1234", bundleIdentifier: "com.yuki-yano.shitsurae.cli"),
            ],
            identityProvider: provider
        )

        XCTAssertFalse(service.authorize(clientPID: 1002, clientUID: 502, currentUID: 501))
    }

    func testAuthorizeRejectsNonAllowlistedIdentity() {
        let provider = StubIdentityProvider(
            identities: [
                1003: XPCClientIdentity(
                    teamIdentifier: "TEAMID1234",
                    bundleIdentifier: "com.example.other",
                    executablePath: "/tmp/other"
                ),
            ]
        )

        let service = XPCAuthService(
            allowlist: [
                XPCAllowedIdentity(teamIdentifier: "TEAMID1234", bundleIdentifier: "com.yuki-yano.shitsurae.cli"),
            ],
            identityProvider: provider
        )

        XCTAssertFalse(service.authorize(clientPID: 1003, clientUID: 501, currentUID: 501))
    }

    func testAuthorizeAllowsAdHocDevelopmentIdentity() {
        let provider = StubIdentityProvider(
            identities: [
                1004: XPCClientIdentity(
                    teamIdentifier: nil,
                    bundleIdentifier: "shitsurae-deadbeef",
                    executablePath: "/tmp/shitsurae"
                ),
            ]
        )

        let service = XPCAuthService(
            allowlist: [
                XPCAllowedIdentity(teamIdentifier: "TEAMID1234", bundleIdentifier: "com.yuki-yano.shitsurae.cli"),
            ],
            identityProvider: provider
        )

        XCTAssertTrue(service.authorize(clientPID: 1004, clientUID: 501, currentUID: 501))
    }

    func testAuthorizeAllowsAdHocDevelopmentIdentityForRenamedAppBundle() {
        let provider = StubIdentityProvider(
            identities: [
                1005: XPCClientIdentity(
                    teamIdentifier: nil,
                    bundleIdentifier: "Shitsurae-deadbeef",
                    executablePath: "/tmp/Shitsurae"
                ),
            ]
        )

        let service = XPCAuthService(
            allowlist: [
                XPCAllowedIdentity(teamIdentifier: "TEAMID1234", bundleIdentifier: "com.yuki-yano.shitsurae.cli"),
            ],
            identityProvider: provider
        )

        XCTAssertTrue(service.authorize(clientPID: 1005, clientUID: 501, currentUID: 501))
    }

    func testAuthorizeRejectsWhenIdentityUnavailable() {
        let service = XPCAuthService(
            allowlist: [
                XPCAllowedIdentity(teamIdentifier: "TEAMID1234", bundleIdentifier: "com.yuki-yano.shitsurae.cli"),
            ],
            identityProvider: StubIdentityProvider(identities: [:])
        )

        XCTAssertFalse(service.authorize(clientPID: 1234, clientUID: 501, currentUID: 501))
    }

    func testAuthorizeAllowsAdHocByExecutableName() {
        let provider = StubIdentityProvider(
            identities: [
                2001: XPCClientIdentity(
                    teamIdentifier: nil,
                    bundleIdentifier: nil,
                    executablePath: "/tmp/Shitsurae"
                ),
            ]
        )

        let service = XPCAuthService(
            allowlist: [],
            identityProvider: provider
        )

        XCTAssertTrue(service.authorize(clientPID: 2001, clientUID: 501, currentUID: 501))
    }

    func testAuthorizeAllowsAdHocByCLIExecutableName() {
        let provider = StubIdentityProvider(
            identities: [
                2002: XPCClientIdentity(
                    teamIdentifier: nil,
                    bundleIdentifier: nil,
                    executablePath: "/tmp/shitsurae-cli"
                ),
            ]
        )

        let service = XPCAuthService(
            allowlist: [],
            identityProvider: provider
        )

        XCTAssertTrue(service.authorize(clientPID: 2002, clientUID: 501, currentUID: 501))
    }

    func testDefaultAllowlistUsesDevelopmentTeamEnv() {
        let envKey = "SHITSURAE_DEVELOPMENT_TEAM"
        let old = ProcessInfo.processInfo.environment[envKey]
        setenv(envKey, "TEAM-FROM-ENV", 1)
        defer {
            if let old {
                setenv(envKey, old, 1)
            } else {
                unsetenv(envKey)
            }
        }

        let allowlist = XPCAuthService.defaultAllowlist()
        XCTAssertEqual(allowlist.count, 2)
        XCTAssertTrue(allowlist.allSatisfy { $0.teamIdentifier == "TEAM-FROM-ENV" })
        XCTAssertEqual(
            Set(allowlist.map(\.bundleIdentifier)),
            Set(["com.yuki-yano.shitsurae", "com.yuki-yano.shitsurae.cli"])
        )
    }
}

private final class StubIdentityProvider: XPCClientIdentityProviding {
    private let identities: [pid_t: XPCClientIdentity]

    init(identities: [pid_t: XPCClientIdentity]) {
        self.identities = identities
    }

    func identity(for pid: pid_t) -> XPCClientIdentity? {
        identities[pid]
    }
}
