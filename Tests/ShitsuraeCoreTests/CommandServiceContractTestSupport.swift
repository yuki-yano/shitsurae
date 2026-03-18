import CoreGraphics
import Foundation
import XCTest
@testable import ShitsuraeCore

class CommandServiceContractTestCase: XCTestCase {
    class var validConfigYAML: String {
        """
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class var multiSpaceConfigYAML: String {
        """
        layouts:
          work:
            spaces:
              - spaceID: 1
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
              - spaceID: 2
                display:
                  monitor: primary
                windows:
                  - slot: 2
                    launch: false
                    match:
                      bundleID: com.apple.Notes
                    frame:
                      x: "50%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class var virtualMultiSpaceConfigYAML: String {
        """
        mode:
          space: virtual
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
              - spaceID: 2
                display:
                  monitor: primary
                windows:
                  - slot: 2
                    launch: false
                    match:
                      bundleID: com.apple.Notes
                    frame:
                      x: "50%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class var virtualThreeWindowConfigYAML: String {
        """
        mode:
          space: virtual
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
              - spaceID: 2
                display:
                  monitor: primary
                windows:
                  - slot: 2
                    launch: false
                    match:
                      bundleID: com.apple.Notes
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
                  - slot: 3
                    launch: false
                    match:
                      bundleID: com.apple.Calendar
                    frame:
                      x: "50%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class var virtualSingleSpaceConfigYAML: String {
        """
        mode:
          space: virtual
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "100%"
                      height: "100%"
        """
    }

    class var overlayThumbnailConfigYAML: String {
        """
        overlay:
          showThumbnails: true
        layouts:
          work:
            spaces:
              - spaceID: 1
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class var switcherConfigYAML: String {
        """
        shortcuts:
          switcher:
            quickKeys: "abc"
            sources: ["window"]
        layouts:
          work:
            spaces:
              - spaceID: 1
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class var virtualExplicitDisplayConfigYAML: String {
        """
        mode:
          space: virtual
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  id: display-a
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
              - spaceID: 2
                display:
                  id: display-a
                windows:
                  - slot: 2
                    launch: false
                    match:
                      bundleID: com.apple.Notes
                    frame:
                      x: "50%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class var virtualSwitcherConfigYAML: String {
        """
        mode:
          space: virtual
        shortcuts:
          switcher:
            quickKeys: "abc"
            sources: ["window"]
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - slot: 3
                    launch: false
                    match:
                      bundleID: com.apple.Calendar
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
              - spaceID: 2
                display:
                  monitor: primary
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
                  - slot: 2
                    launch: false
                    match:
                      bundleID: com.apple.Notes
                    frame:
                      x: "50%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class var virtualMultiSpaceWithInitialFocusConfigYAML: String {
        """
        mode:
          space: virtual
        layouts:
          work:
            initialFocus:
              slot: 1
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
              - spaceID: 2
                display:
                  monitor: primary
                windows:
                  - slot: 2
                    launch: false
                    match:
                      bundleID: com.apple.Notes
                    frame:
                      x: "50%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class var ignoreFocusConfigYAML: String {
        """
        ignore:
          focus:
            apps:
              - com.apple.TextEdit
        layouts:
          work:
            spaces:
              - spaceID: 1
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "0%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """
    }

    class func isRFC3339UTCWithFractionalSeconds(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value) != nil
    }

    class func window(
        windowID: UInt32,
        bundleID: String,
        title: String,
        spaceID: Int?,
        frontIndex: Int,
        minimized: Bool = false
    ) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: bundleID,
            pid: Int(windowID),
            title: title,
            role: "AXWindow",
            subrole: nil,
            minimized: minimized,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 640, height: 480),
            spaceID: spaceID,
            displayID: "display-a",
            isFullscreen: false,
            frontIndex: frontIndex
        )
    }

    func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
    }
}

struct TestConfigWorkspace {
    let root: URL
    let xdgConfigHome: URL
    let configDirectory: URL
    let stateFileURL: URL
    let supportedBuildCatalogURL: URL

    init(files: [String: String]) throws {
        let fm = FileManager.default
        let tempBase = fm.temporaryDirectory
            .appendingPathComponent("shitsurae-tests-\(UUID().uuidString)", isDirectory: true)
        let xdgConfigHome = tempBase.appendingPathComponent("xdg", isDirectory: true)
        let configDirectory = xdgConfigHome.appendingPathComponent("shitsurae", isDirectory: true)
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        for (name, content) in files {
            let url = configDirectory.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        let stateFileURL = tempBase.appendingPathComponent("runtime-state.json")
        let supportedBuildCatalogURL = tempBase.appendingPathComponent("supported-build-catalog.json")
        let currentBuildVersion = SystemProbe.currentBuildVersion() ?? "UNKNOWN_BUILD"
        try """
        {
          "allowStatusesForRuntime": ["supported"],
          "builds": [
            { "productVersion": "0.0.0", "productBuildVersion": "\(currentBuildVersion)", "status": "supported" }
          ]
        }
        """.write(to: supportedBuildCatalogURL, atomically: true, encoding: .utf8)

        self.root = tempBase
        self.xdgConfigHome = xdgConfigHome
        self.configDirectory = configDirectory
        self.stateFileURL = stateFileURL
        self.supportedBuildCatalogURL = supportedBuildCatalogURL
    }

    func makeService(
        stateStore: RuntimeStateStore? = nil,
        diagnosticEventStore: DiagnosticEventStore = DiagnosticEventStore(),
        supportedBuildCatalogURL: URL? = nil,
        arrangeDriver: ArrangeDriver = ContractTestArrangeDriver(),
        arrangeRequestDeduplicator: ArrangeRequestDeduplicating? = nil,
        stateMutationLock: VirtualSpaceStateMutationLock? = nil,
        stateMutationLockTimeoutMS: Int = VirtualSpaceStateMutationLock.lockWaitTimeoutMS,
        stateMutationLockPollIntervalMS: Int = VirtualSpaceStateMutationLock.defaultPollIntervalMS,
        runtimeHooks: CommandServiceRuntimeHooks = .live,
        configDirectoryOverride: URL? = nil
    ) -> CommandService {
        let effectiveStateStore = stateStore ?? RuntimeStateStore(stateFileURL: stateFileURL)
        return CommandService(
            stateStore: effectiveStateStore,
            diagnosticEventStore: diagnosticEventStore,
            stateMutationLock: stateMutationLock,
            stateMutationLockTimeoutMS: stateMutationLockTimeoutMS,
            stateMutationLockPollIntervalMS: stateMutationLockPollIntervalMS,
            supportedBuildCatalogURL: supportedBuildCatalogURL ?? self.supportedBuildCatalogURL,
            arrangeDriver: arrangeDriver,
            arrangeRequestDeduplicator: arrangeRequestDeduplicator,
            enableAutoReloadMonitor: false,
            environment: [
                "XDG_CONFIG_HOME": xdgConfigHome.path,
                "HOME": root.path,
            ],
            configDirectoryOverride: configDirectoryOverride,
            runtimeHooks: runtimeHooks
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func currentConfigGeneration() throws -> String {
        try ConfigLoader().load(from: configDirectory).configGeneration
    }
}

struct ContractTestArrangeDriver: ArrangeDriver {
    func displays() -> [DisplayInfo] {
        [
            DisplayInfo(
                id: "display-a",
                width: 1440,
                height: 900,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
        ]
    }

    func spaces() -> [SpaceInfo] {
        [
            SpaceInfo(spaceID: 1, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
        ]
    }

    func queryWindows() -> [WindowSnapshot] { [] }
    func queryWindowsOnAllSpaces() -> [WindowSnapshot] { [] }
    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { true }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (true, nil) }
}

struct VirtualArrangeTestDriver: ArrangeDriver {
    let windows: [WindowSnapshot]

    func displays() -> [DisplayInfo] {
        [
            DisplayInfo(
                id: "display-a",
                width: 3200,
                height: 2000,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
            ),
        ]
    }

    func spaces() -> [SpaceInfo] {
        [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
    }

    func queryWindows() -> [WindowSnapshot] { windows }
    func queryWindowsOnAllSpaces() -> [WindowSnapshot] { windows }
    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { true }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (true, nil) }
}

final class AlwaysFailingCreateDirectoryFileManager: FileManager {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [
            NSLocalizedDescriptionKey: "simulated createDirectory failure",
        ])
    }
}

final class BlockingCreateDirectoryFileManager: FileManager {
    private let stateLock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var hasBlocked = false
    var onBlockedCreateDirectory: (() -> Void)?

    func releaseBlockedCreateDirectory() {
        releaseSemaphore.signal()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )

        let shouldBlock: Bool
        stateLock.lock()
        shouldBlock = !hasBlocked
        if shouldBlock {
            hasBlocked = true
        }
        stateLock.unlock()

        guard shouldBlock else {
            return
        }

        onBlockedCreateDirectory?()
        _ = releaseSemaphore.wait(timeout: .now() + 5)
    }
}

final class FailingCreateDirectoryCallFileManager: FileManager {
    private let failingCallIndexes: Set<Int>
    private var createDirectoryCallCount = 0

    init(failingCallIndexes: Set<Int>) {
        self.failingCallIndexes = failingCallIndexes
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        createDirectoryCallCount += 1
        if failingCallIndexes.contains(createDirectoryCallCount) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [
                NSLocalizedDescriptionKey: "simulated createDirectory failure",
            ])
        }

        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}

final class MutatingCreateDirectoryFileManager: FileManager {
    private let stateFileURL: URL
    private let replacementState: RuntimeState
    private let mutationCallIndex: Int
    private var createDirectoryCallCount = 0

    init(stateFileURL: URL, replacementState: RuntimeState, mutationCallIndex: Int = 1) {
        self.stateFileURL = stateFileURL
        self.replacementState = replacementState
        self.mutationCallIndex = mutationCallIndex
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
        createDirectoryCallCount += 1
        guard createDirectoryCallCount == mutationCallIndex else {
            return
        }
        let data = try JSONEncoder.pretty.encode(replacementState)
        try data.write(to: stateFileURL, options: .atomic)
    }
}

final class NeverSuppressArrangeDeduplicator: ArrangeRequestDeduplicating {
    func shouldSuppress(layoutName _: String, spaceID _: Int?) -> Bool { false }
}

final class UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T

    init(value: T) {
        self.value = value
    }
}

final class LockedValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func makeRuntimeHooks(
    accessibilityGranted: @escaping () -> Bool = { true },
    listWindows: @escaping () -> [WindowSnapshot] = { [] },
    focusedWindow: @escaping () -> WindowSnapshot? = { nil },
    activateBundle: @escaping (String) -> Bool = { _ in true },
    activateWindowWithTitle: @escaping (String, String) -> Bool = { _, _ in true },
    focusWindow: @escaping (UInt32, String) -> WindowInteractionResult = { _, _ in .success },
    setWindowMinimized: @escaping (UInt32, String, Bool) -> WindowInteractionResult = { _, _, _ in .success },
    setFocusedWindowFrame: @escaping (ResolvedFrame) -> Bool = { _ in true },
    setWindowFrame: @escaping (UInt32, String, ResolvedFrame) -> Bool = { _, _, _ in true },
    setWindowPosition: @escaping (UInt32, String, CGPoint) -> Bool = { _, _, _ in true },
    displays: @escaping () -> [DisplayInfo] = { [] },
    spaces: @escaping () -> [SpaceInfo] = { [] },
    runProcess: @escaping (String, [String]) -> (exitCode: Int32, output: String) = { _, _ in (0, "") },
    listWindowsOnAllSpaces: @escaping () -> [WindowSnapshot] = { [] },
    now: @escaping () -> Date = Date.init
) -> CommandServiceRuntimeHooks {
    CommandServiceRuntimeHooks(
        accessibilityGranted: accessibilityGranted,
        listWindows: listWindows,
        focusedWindow: focusedWindow,
        activateBundle: activateBundle,
        setFocusedWindowFrame: setFocusedWindowFrame,
        displays: displays,
        runProcess: runProcess,
        activateWindowWithTitle: activateWindowWithTitle,
        focusWindow: focusWindow,
        setWindowMinimized: setWindowMinimized,
        setWindowFrame: setWindowFrame,
        setWindowPosition: setWindowPosition,
        spaces: spaces,
        listWindowsOnAllSpaces: listWindowsOnAllSpaces,
        now: now
    )
}

final class SerializingVirtualArrangeDriver: ArrangeDriver {
    private let lock = NSLock()
    private let firstQueryRelease = DispatchSemaphore(value: 0)
    private var hasBlockedFirstQuery = false
    private(set) var queryInvocationCount = 0
    var onFirstQueryEntered: (() -> Void)?

    func releaseFirstQuery() {
        firstQueryRelease.signal()
    }

    func displays() -> [DisplayInfo] {
        [
            DisplayInfo(
                id: "display-a",
                width: 1440,
                height: 900,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
        ]
    }

    func spaces() -> [SpaceInfo] {
        [
            SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
        ]
    }

    func queryWindows() -> [WindowSnapshot] {
        queryWindowsOnAllSpaces()
    }

    func queryWindowsOnAllSpaces() -> [WindowSnapshot] {
        let shouldBlockFirstQuery: Bool
        lock.lock()
        queryInvocationCount += 1
        shouldBlockFirstQuery = !hasBlockedFirstQuery
        if shouldBlockFirstQuery {
            hasBlockedFirstQuery = true
        }
        lock.unlock()

        if shouldBlockFirstQuery {
            onFirstQueryEntered?()
            _ = firstQueryRelease.wait(timeout: .now() + 5)
        }

        return [
            WindowSnapshot(
                windowID: 801,
                bundleID: "com.apple.TextEdit",
                pid: 9001,
                title: "Untitled",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 800, height: 600),
                spaceID: 7,
                displayID: "display-a",
                isFullscreen: false,
                frontIndex: 0
            ),
        ]
    }

    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { true }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (true, nil) }
}

func virtualSwitchSuccessRuntimeHooks() -> CommandServiceRuntimeHooks {
    makeRuntimeHooks(
        displays: {
            [
                DisplayInfo(
                    id: "display-a",
                    width: 3200,
                    height: 2000,
                    scale: 2.0,
                    isPrimary: true,
                    frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                    visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
                ),
            ]
        },
        spaces: {
            [
                SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
            ]
        },
        listWindowsOnAllSpaces: {
            [
                WindowSnapshot(
                    windowID: 800,
                    bundleID: "com.apple.TextEdit",
                    pid: 4000,
                    title: "Editor",
                    role: "AXWindow",
                    subrole: nil,
                    minimized: false,
                    hidden: false,
                    frame: ResolvedFrame(x: 0, y: 0, width: 1200, height: 800),
                    spaceID: 7,
                    displayID: "display-a",
                    isFullscreen: false,
                    frontIndex: 1
                ),
                WindowSnapshot(
                    windowID: 801,
                    bundleID: "com.apple.Notes",
                    pid: 4001,
                    title: "Notes",
                    role: "AXWindow",
                    subrole: nil,
                    minimized: true,
                    hidden: false,
                    frame: ResolvedFrame(x: 0, y: 0, width: 1200, height: 800),
                    spaceID: 7,
                    displayID: "display-a",
                    isFullscreen: false,
                    frontIndex: 0
                ),
            ]
        }
    )
}

struct BackendUnavailableArrangeDriver: ArrangeDriver {
    func displays() -> [DisplayInfo] { [] }
    func spaces() -> [SpaceInfo] { [] }
    func queryWindows() -> [WindowSnapshot] { [] }
    func queryWindowsOnAllSpaces() -> [WindowSnapshot] { [] }
    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { true }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (false, "unsupportedOSBuild") }
}

struct MissingPermissionArrangeDriver: ArrangeDriver {
    func displays() -> [DisplayInfo] { [] }
    func spaces() -> [SpaceInfo] { [] }
    func queryWindows() -> [WindowSnapshot] { [] }
    func queryWindowsOnAllSpaces() -> [WindowSnapshot] { [] }
    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { false }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (true, nil) }
}

struct VirtualHostUnavailableArrangeDriver: ArrangeDriver {
    func displays() -> [DisplayInfo] {
        [
            DisplayInfo(
                id: "display-a",
                width: 3200,
                height: 2000,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 980)
            ),
            DisplayInfo(
                id: "display-b",
                width: 2560,
                height: 1440,
                scale: 2.0,
                isPrimary: false,
                frame: CGRect(x: 1600, y: 0, width: 1280, height: 720),
                visibleFrame: CGRect(x: 1600, y: 0, width: 1280, height: 680)
            ),
        ]
    }

    func spaces() -> [SpaceInfo] {
        [
            SpaceInfo(spaceID: 1, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
            SpaceInfo(spaceID: 2, displayID: "display-b", isVisible: true, isNativeFullscreen: false),
        ]
    }

    func queryWindows() -> [WindowSnapshot] { [] }
    func queryWindowsOnAllSpaces() -> [WindowSnapshot] { [] }
    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { true }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (true, nil) }
}

struct VirtualUnresolvedSlotsArrangeDriver: ArrangeDriver {
    func displays() -> [DisplayInfo] {
        [
            DisplayInfo(
                id: "display-a",
                width: 3200,
                height: 2000,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 980)
            ),
        ]
    }

    func spaces() -> [SpaceInfo] {
        [
            SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
        ]
    }

    func queryWindows() -> [WindowSnapshot] {
        [
            WindowSnapshot(
                windowID: 900,
                bundleID: "com.apple.TextEdit",
                pid: 900,
                title: "Editor",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
                spaceID: 8,
                displayID: "display-a",
                isFullscreen: false,
                frontIndex: 0
            ),
        ]
    }

    func queryWindowsOnAllSpaces() -> [WindowSnapshot] {
        queryWindows()
    }

    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { true }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (true, nil) }
}

struct VirtualSuccessfulArrangeDriver: ArrangeDriver {
    func displays() -> [DisplayInfo] {
        [
            DisplayInfo(
                id: "display-a",
                width: 3200,
                height: 2000,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 980)
            ),
        ]
    }

    func spaces() -> [SpaceInfo] {
        [
            SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
        ]
    }

    func queryWindows() -> [WindowSnapshot] {
        queryWindowsOnAllSpaces()
    }

    func queryWindowsOnAllSpaces() -> [WindowSnapshot] {
        [
            WindowSnapshot(
                windowID: 900,
                bundleID: "com.apple.TextEdit",
                pid: 900,
                title: "Editor",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
                spaceID: 7,
                displayID: "display-a",
                isFullscreen: false,
                frontIndex: 0
            ),
        ]
    }

    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { true }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (true, nil) }
}
