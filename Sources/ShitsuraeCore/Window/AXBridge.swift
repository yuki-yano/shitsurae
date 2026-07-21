import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func AXUIElementGetWindowID(_ element: AXUIElement, _ idOut: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID")
@discardableResult
func LegacyGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

func checkedAXUIElement(_ value: CFTypeRef) -> AXUIElement? {
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

func checkedAXValue(_ value: CFTypeRef, type: AXValueType) -> AXValue? {
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == type else { return nil }
    return axValue
}

func axWindowIDBridgeAvailable() -> Bool {
    guard let handle = dlopen(nil, RTLD_LAZY) else { return false }
    defer { dlclose(handle) }
    return dlsym(handle, "_AXUIElementGetWindow") != nil
}

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
    private nonisolated(unsafe) static let frameworkHandle = dlopen(frameworkPath, RTLD_LAZY)

    static var targetedWindowFocusAvailable: Bool {
        setFrontProcessWithOptions() != nil && postEventRecordTo() != nil
    }

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
        guard let frameworkHandle,
              let raw = dlsym(frameworkHandle, symbol)
        else {
            return nil
        }

        return unsafeBitCast(raw, to: T.self)
    }
}
