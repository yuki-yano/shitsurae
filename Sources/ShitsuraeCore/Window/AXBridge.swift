import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func AXUIElementGetWindowID(_ element: AXUIElement, _ idOut: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Bounds read-only AX IPC without changing the timeout used by window
/// mutations. A single application that stops servicing Accessibility must
/// not serialize every Shitsurae command behind the system default timeout.
public enum AXReadPolicy {
    public static let messagingTimeoutSeconds: Float = 0.25

    @discardableResult
    public static func apply(to element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
    }
}

/// Suppresses overlapping AX inventory reads for the same process generation
/// and briefly backs off after an application-level
/// `kAXErrorCannotComplete`. The CG inventory remains authoritative, so
/// skipping AX metadata during this window cannot release a live binding.
final class AXEnumerationGate: @unchecked Sendable {
    fileprivate struct Key: Hashable {
        let pid: Int
        let processStartTime: UInt64
        let bundleID: String
    }

    private enum Entry {
        case inFlight(UInt64)
        case retryAfter(Date)
    }

    struct Lease {
        fileprivate let key: Key
        fileprivate let token: UInt64

        fileprivate init(key: Key, token: UInt64) {
            self.key = key
            self.token = token
        }
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var nextToken: UInt64 = 0
    private let retryInterval: TimeInterval

    init(retryInterval: TimeInterval = 5) {
        self.retryInterval = retryInterval
    }

    func begin(
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        now: Date = Date()
    ) -> Lease? {
        let key = Key(
            pid: pid,
            processStartTime: processStartTime,
            bundleID: bundleID
        )

        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { _, entry in
            if case let .retryAfter(deadline) = entry {
                return deadline > now
            }
            return true
        }
        guard entries[key] == nil else { return nil }
        nextToken &+= 1
        let lease = Lease(key: key, token: nextToken)
        entries[key] = .inFlight(lease.token)
        return lease
    }

    func finish(
        _ lease: Lease,
        shouldBackOff: Bool,
        now: Date = Date()
    ) {
        lock.lock()
        guard case let .inFlight(currentToken) = entries[lease.key],
              currentToken == lease.token
        else {
            lock.unlock()
            return
        }
        if shouldBackOff {
            entries[lease.key] = .retryAfter(now.addingTimeInterval(retryInterval))
        } else {
            entries.removeValue(forKey: lease.key)
        }
        lock.unlock()
    }
}

@_silgen_name("GetProcessForPID")
@discardableResult
func LegacyGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SLPSMode: UInt32 {
    case userGenerated = 0x200
}

private typealias CSetFrontProcessWithOptionsFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>,
    CGWindowID,
    UInt32
) -> CGError

private typealias CPostEventRecordToFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>,
    UnsafeMutablePointer<UInt8>
) -> CGError

typealias SetFrontProcessWithOptionsCall = (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
typealias PostEventRecordToCall = (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

/// The only remaining SkyLight private-API surface in v2: targeted window
/// front-most promotion. _SLPSSetFrontProcessWithOptions is the sole way to
/// raise one specific window without raising the app's other windows.
enum SkyLightSymbols {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    static func setFrontProcessWithOptions() -> SetFrontProcessWithOptionsCall? {
        guard let function = resolve("_SLPSSetFrontProcessWithOptions", as: CSetFrontProcessWithOptionsFn.self) else {
            return nil
        }

        return { psn, windowID, mode in
            function(psn, windowID, mode)
        }
    }

    static func postEventRecordTo() -> PostEventRecordToCall? {
        guard let function = resolve("SLPSPostEventRecordTo", as: CPostEventRecordToFn.self) else {
            return nil
        }

        return { psn, bytes in
            function(psn, bytes)
        }
    }

    private static func resolve<T>(_ symbol: String, as _: T.Type) -> T? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let raw = dlsym(handle, symbol)
        else {
            return nil
        }

        return unsafeBitCast(raw, to: T.self)
    }
}
