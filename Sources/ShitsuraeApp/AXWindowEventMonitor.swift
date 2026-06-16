import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func AppAXUIElementGetWindowID(_ element: AXUIElement, _ idOut: UnsafeMutablePointer<CGWindowID>) -> AXError

final class AXWindowEventMonitor {
    enum Event: Sendable, Equatable {
        case windowCreated(bundleID: String, pid: pid_t, windowID: UInt32?)
        case focusedWindowChanged(bundleID: String, pid: pid_t, windowID: UInt32?)
    }

    private final class CallbackContext {
        weak var monitor: AXWindowEventMonitor?
        let pid: pid_t
        let bundleID: String

        init(monitor: AXWindowEventMonitor, pid: pid_t, bundleID: String) {
            self.monitor = monitor
            self.pid = pid
            self.bundleID = bundleID
        }
    }

    private struct ObserverRecord {
        let observer: AXObserver
        let appElement: AXUIElement
        let context: CallbackContext
    }

    private var observers: [pid_t: ObserverRecord] = [:]
    private var handler: (@Sendable (Event) -> Void)?

    func start(handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
        refreshRunningApplications()
    }

    func stop() {
        for record in observers.values {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(record.observer),
                .commonModes
            )
        }
        observers.removeAll()
        handler = nil
    }

    func refreshRunningApplications() {
        for app in NSWorkspace.shared.runningApplications {
            register(application: app)
        }
    }

    func register(application: NSRunningApplication) {
        guard AXIsProcessTrusted(),
              let bundleID = application.bundleIdentifier,
              !bundleID.hasPrefix("com.yuki-yano.shitsurae"),
              bundleID != Bundle.main.bundleIdentifier
        else {
            return
        }

        let pid = application.processIdentifier
        guard observers[pid] == nil else {
            return
        }

        var observerRef: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &observerRef) == .success,
              let observer = observerRef
        else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let context = CallbackContext(monitor: self, pid: pid, bundleID: bundleID)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque())

        let notifications = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
        ]

        for notification in notifications {
            let result = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            guard result == .success || result == .notificationAlreadyRegistered else {
                continue
            }
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = ObserverRecord(observer: observer, appElement: appElement, context: context)
    }

    func unregister(pid: pid_t) {
        guard let record = observers.removeValue(forKey: pid) else {
            return
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(record.observer),
            .commonModes
        )
    }

    private func handle(notification: CFString, element: AXUIElement, pid: pid_t, bundleID: String) {
        guard let handler else {
            return
        }

        let windowID = Self.windowID(from: element)
        if CFEqual(notification, kAXWindowCreatedNotification as CFString) {
            handler(.windowCreated(bundleID: bundleID, pid: pid, windowID: windowID))
        } else if CFEqual(notification, kAXFocusedWindowChangedNotification as CFString) {
            handler(.focusedWindowChanged(bundleID: bundleID, pid: pid, windowID: windowID))
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
            bundleID: context.bundleID
        )
    }

    private static func windowID(from element: AXUIElement) -> UInt32? {
        if let direct = windowID(of: element) {
            return direct
        }

        for attribute in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
                  let ref
            else {
                continue
            }

            if let resolved = windowID(of: ref as! AXUIElement) {
                return resolved
            }
        }

        return nil
    }

    private static func windowID(of element: AXUIElement) -> UInt32? {
        var windowID: CGWindowID = 0
        guard AppAXUIElementGetWindowID(element, &windowID) == .success else {
            return nil
        }
        return UInt32(windowID)
    }
}
