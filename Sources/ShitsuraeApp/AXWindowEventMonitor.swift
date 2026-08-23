import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ShitsuraeCore

@_silgen_name("_AXUIElementGetWindow")
private func AppAXUIElementGetWindowID(_ element: AXUIElement, _ idOut: UnsafeMutablePointer<CGWindowID>) -> AXError

final class AXWindowEventMonitor: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case focusedWindowChanged(
            sequence: UInt64,
            bundleID: String,
            pid: pid_t,
            processStartTime: UInt64,
            windowID: UInt32?
        )
    }

    private final class CallbackContext {
        weak var monitor: AXWindowEventMonitor?
        let pid: pid_t
        let bundleID: String
        let processStartTime: UInt64
        let launchDate: Date?

        init(
            monitor: AXWindowEventMonitor,
            pid: pid_t,
            bundleID: String,
            processStartTime: UInt64,
            launchDate: Date?
        ) {
            self.monitor = monitor
            self.pid = pid
            self.bundleID = bundleID
            self.processStartTime = processStartTime
            self.launchDate = launchDate
        }
    }

    private struct ObserverRecord {
        let observer: AXObserver
        let appElement: AXUIElement
        let context: CallbackContext
    }

    private let applicationProvider: () -> [NSRunningApplication]
    private let registrationHook: (@Sendable (NSRunningApplication) -> Void)?
    private let lifecycleLock = NSLock()
    private var observers: [pid_t: ObserverRecord] = [:]
    private var handler: (@Sendable (Event) -> Void)?
    private var monitorThread: Thread?
    private var monitorRunLoop: CFRunLoop?
    private var pendingOperations: [() -> Void] = []
    private var stopping = false
    private static let sequenceLock = NSLock()
    private nonisolated(unsafe) static var sourceSequence: UInt64 = 0

    init(
        applicationProvider: @escaping () -> [NSRunningApplication] = {
            NSWorkspace.shared.runningApplications
        },
        registrationHook: (@Sendable (NSRunningApplication) -> Void)? = nil
    ) {
        self.applicationProvider = applicationProvider
        self.registrationHook = registrationHook
    }

    static func nextSequence() -> UInt64 {
        Self.sequenceLock.lock()
        defer { Self.sequenceLock.unlock() }
        Self.sourceSequence &+= 1
        return Self.sourceSequence
    }

    /// Starts AX registration on a dedicated run loop. AX notification
    /// registration performs synchronous cross-process IPC and a single
    /// unresponsive application can stall for more than a second, so none of
    /// this work may run on the main thread during application launch.
    func start(
        handler: @escaping @Sendable (Event) -> Void,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in },
        completion: @escaping @Sendable () -> Void = {}
    ) {
        let applications = applicationProvider()

        lifecycleLock.lock()
        guard monitorThread == nil else {
            lifecycleLock.unlock()
            return
        }
        self.handler = handler
        stopping = false

        let thread = Thread { [weak self] in
            self?.run(
                initialApplications: applications,
                progress: progress,
                completion: completion
            )
        }
        thread.name = "Shitsurae AX Window Monitor"
        thread.qualityOfService = .userInitiated
        monitorThread = thread
        lifecycleLock.unlock()

        progress(0, applications.count)
        thread.start()
    }

    func stop() {
        lifecycleLock.lock()
        stopping = true
        handler = nil
        pendingOperations.removeAll()
        let runLoop = monitorRunLoop
        lifecycleLock.unlock()

        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    func refreshRunningApplications() {
        for app in applicationProvider() {
            register(application: app)
        }
    }

    func register(application: NSRunningApplication) {
        performOnMonitorThread { [weak self] in
            self?.registerOnMonitorThread(application: application)
        }
    }

    func focusedWindowID(application: NSRunningApplication) -> UInt32? {
        guard AXIsProcessTrusted() else {
            return nil
        }
        return Self.windowID(from: AXUIElementCreateApplication(application.processIdentifier))
    }

    func unregister(application: NSRunningApplication) {
        performOnMonitorThread { [weak self] in
            self?.unregisterOnMonitorThread(application: application)
        }
    }

    private func run(
        initialApplications: [NSRunningApplication],
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void,
        completion: @escaping @Sendable () -> Void
    ) {
        let runLoop = CFRunLoopGetCurrent()
        var sourceContext = CFRunLoopSourceContext()
        guard let keepAliveSource = CFRunLoopSourceCreate(nil, 0, &sourceContext) else {
            completion()
            return
        }
        CFRunLoopAddSource(runLoop, keepAliveSource, .defaultMode)

        lifecycleLock.lock()
        monitorRunLoop = runLoop
        let pending = pendingOperations
        pendingOperations.removeAll()
        let shouldStop = stopping
        lifecycleLock.unlock()

        defer {
            for record in observers.values {
                CFRunLoopRemoveSource(
                    runLoop,
                    AXObserverGetRunLoopSource(record.observer),
                    .defaultMode
                )
            }
            observers.removeAll()
            CFRunLoopRemoveSource(runLoop, keepAliveSource, .defaultMode)

            lifecycleLock.lock()
            monitorRunLoop = nil
            monitorThread = nil
            pendingOperations.removeAll()
            handler = nil
            lifecycleLock.unlock()
        }

        guard !shouldStop else { return }

        pending.forEach { $0() }

        let total = initialApplications.count
        for (index, application) in initialApplications.enumerated() {
            guard !isStopping else { return }
            registerOnMonitorThread(application: application)

            let completed = index + 1
            if completed == total || completed.isMultiple(of: 10) {
                progress(completed, total)
            }
        }

        guard !isStopping else { return }
        completion()

        while !isStopping {
            CFRunLoopRunInMode(.defaultMode, 60, false)
        }
    }

    private var isStopping: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return stopping
    }

    private func performOnMonitorThread(_ operation: @escaping () -> Void) {
        lifecycleLock.lock()
        guard monitorThread != nil, !stopping else {
            lifecycleLock.unlock()
            return
        }

        guard let runLoop = monitorRunLoop else {
            pendingOperations.append(operation)
            lifecycleLock.unlock()
            return
        }
        lifecycleLock.unlock()

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, operation)
        CFRunLoopWakeUp(runLoop)
    }

    private func registerOnMonitorThread(application: NSRunningApplication) {
        if let registrationHook {
            registrationHook(application)
            return
        }

        let pid = application.processIdentifier
        guard AXIsProcessTrusted(),
              !application.isTerminated,
              let suppliedBundleID = application.bundleIdentifier,
              let currentApplication = NSRunningApplication(processIdentifier: pid),
              !currentApplication.isTerminated,
              currentApplication.bundleIdentifier == suppliedBundleID,
              currentApplication.launchDate == application.launchDate,
              let processStartTime = ProcessGenerationResolver.startTime(
                  pid: Int(pid)
              ),
              !suppliedBundleID.hasPrefix("com.yuki-yano.shitsurae"),
              suppliedBundleID != Bundle.main.bundleIdentifier
        else {
            return
        }
        let bundleID = suppliedBundleID

        if let existing = observers[pid] {
            if existing.context.processStartTime == processStartTime,
               existing.context.bundleID == bundleID,
               existing.context.launchDate == currentApplication.launchDate
            {
                return
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(existing.observer),
                .defaultMode
            )
            observers.removeValue(forKey: pid)
        }

        var observerRef: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &observerRef) == .success,
              let observer = observerRef
        else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let context = CallbackContext(
            monitor: self,
            pid: pid,
            bundleID: bundleID,
            processStartTime: processStartTime,
            launchDate: currentApplication.launchDate
        )
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque())

        let notifications = [kAXFocusedWindowChangedNotification]

        var registeredNotification = false
        for notification in notifications {
            let result = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            if result == .success || result == .notificationAlreadyRegistered {
                registeredNotification = true
            }
        }

        // Do not cache an inert observer. A later activation/refresh must be
        // able to retry when Chrome was temporarily unavailable to AX during
        // launch or automation startup.
        guard registeredNotification else { return }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = ObserverRecord(observer: observer, appElement: appElement, context: context)
    }

    private func unregisterOnMonitorThread(application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard let record = observers[pid] else { return }
        if let terminatedLaunchDate = application.launchDate,
           let observedLaunchDate = record.context.launchDate
        {
            guard terminatedLaunchDate == observedLaunchDate else { return }
        } else {
            // Some non-LaunchServices applications have no launchDate. Only
            // remove their record once the kernel confirms no process owns
            // this PID. If the PID has already been reused, register() will
            // compare process generations and replace the stale observer;
            // an old terminate notification must never remove the new one.
            guard ProcessGenerationResolver.startTime(pid: Int(pid)) == nil else { return }
        }
        observers.removeValue(forKey: pid)
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(record.observer),
            .defaultMode
        )
    }

    private func handle(
        notification: CFString,
        element: AXUIElement,
        pid: pid_t,
        bundleID: String,
        processStartTime: UInt64
    ) {
        // A queued callback from a terminated process can arrive after macOS
        // has reused its PID. Reject it before sequence allocation so it
        // cannot supersede a valid focus event from the new process instance.
        lifecycleLock.lock()
        let handler = handler
        lifecycleLock.unlock()

        guard ProcessGenerationResolver.startTime(pid: Int(pid)) == processStartTime,
              let handler
        else { return }

        let windowID = Self.windowID(from: element)
        if CFEqual(notification, kAXFocusedWindowChangedNotification as CFString) {
            handler(.focusedWindowChanged(
                sequence: Self.nextSequence(),
                bundleID: bundleID,
                pid: pid,
                processStartTime: processStartTime,
                windowID: windowID
            ))
        }
    }

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else {
            return
        }
        let context = Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue()
        context.monitor?.handle(
            notification: notification,
            element: element,
            pid: context.pid,
            bundleID: context.bundleID,
            processStartTime: context.processStartTime
        )
    }

    private static func windowID(from element: AXUIElement) -> UInt32? {
        if let direct = windowID(of: element) {
            return direct
        }

        // Main window is not a focus fallback: Chrome can keep a different
        // main window while DevTools automation changes the focused window.
        // Returning it would consume the activation retry with a stale sibling
        // (the engine rejects it later, but the real focus event is then lost).
        AXReadPolicy.apply(to: element)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }
        return windowID(of: focusedRef as! AXUIElement)
    }

    private static func windowID(of element: AXUIElement) -> UInt32? {
        AXReadPolicy.apply(to: element)
        var windowID: CGWindowID = 0
        guard AppAXUIElementGetWindowID(element, &windowID) == .success else {
            return nil
        }
        return UInt32(windowID)
    }
}
