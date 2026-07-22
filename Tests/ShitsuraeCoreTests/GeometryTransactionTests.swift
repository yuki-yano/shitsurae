import CoreGraphics
import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("Geometry transaction")
struct GeometryTransactionTests {
    @Test
    func selfTargetedWindowInteractionRunsOnMainThread() async {
        let ranOnMainThread = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning:
                    LiveWindowControl.performWindowInteractionOnRequiredThread(
                        pid: Int(ProcessInfo.processInfo.processIdentifier),
                        bundleID: "com.yuki-yano.shitsurae"
                    ) {
                        Thread.isMainThread
                    }
                )
            }
        }

        #expect(ranOnMainThread)
    }

    @Test
    func externalWindowInteractionStaysOnCallingThread() async {
        let ranOnMainThread = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning:
                    LiveWindowControl.performWindowInteractionOnRequiredThread(
                        pid: Int(ProcessInfo.processInfo.processIdentifier),
                        bundleID: "com.openai.chat"
                    ) {
                        Thread.isMainThread
                    }
                )
            }
        }

        #expect(!ranOnMainThread)
    }

    @Test @MainActor
    func selfTargetedWindowInteractionAlreadyOnMainThreadRunsInline() {
        let ranOnMainThread = LiveWindowControl.performWindowInteractionOnRequiredThread(
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            bundleID: "com.yuki-yano.shitsurae"
        ) {
            Thread.isMainThread
        }

        #expect(ranOnMainThread)
    }

    @Test func rollsBackSizeWhenPositionFailsAfterMutating() {
        let initial = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        var actual = initial
        var writes: [String] = []
        let requested = ResolvedFrame(x: 500, y: 300, width: 700, height: 500)

        let outcome = GeometryTransaction.applyFrame(
            initial: initial,
            requested: requested,
            setSize: { size in
                writes.append("size")
                actual.size = size
                return true
            },
            setPosition: { point in
                writes.append("position")
                if point == requested.cgRect.origin {
                    // Chrome sheets can move even though the AX setter reports
                    // failure. The compensating path must still restore it.
                    actual.origin.x += point.x
                    actual.origin.y = point.y
                    return false
                }
                actual.origin = point
                return true
            },
            readFrame: { actual }
        )

        #expect(outcome == .rejectedAndRestored)
        #expect(actual == initial)
        #expect(writes == ["size", "position", "size", "position", "size"])
    }

    @Test func reportsWhenCompensationCannotRestoreThePhysicalFrame() {
        let initial = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        var actual = initial

        let outcome = GeometryTransaction.applyPosition(
            initial: initial,
            requested: CGPoint(x: 5_119, y: 80),
            setPosition: { point in
                actual.origin.x += point.x
                return false
            },
            setSize: {
                actual.size = $0
                return true
            },
            readFrame: { actual }
        )

        #expect(outcome == .failedToRestore)
        #expect(actual.origin != initial.origin)
    }

    @Test func restoresPositionWhenRejectedSetterHasSideEffect() {
        let initial = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let requested = CGPoint(x: 5_119, y: 80)
        var actual = initial

        let outcome = GeometryTransaction.applyPosition(
            initial: initial,
            requested: requested,
            setPosition: { point in
                actual.origin = point
                return point != requested
            },
            setSize: {
                actual.size = $0
                return true
            },
            readFrame: { actual }
        )

        #expect(outcome == .rejectedAndRestored)
        #expect(actual == initial)
    }

    @Test func restoresFullFrameWhenPositionSetterChangesSize() {
        let initial = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let requested = CGPoint(x: 500, y: 300)
        var actual = initial

        let outcome = GeometryTransaction.applyPosition(
            initial: initial,
            requested: requested,
            setPosition: { point in
                actual.origin = point
                if point == requested {
                    actual.size = CGSize(width: 448, height: 240)
                }
                return true
            },
            setSize: {
                actual.size = $0
                return true
            },
            readFrame: { actual }
        )

        #expect(outcome == .rejectedAndRestored)
        #expect(actual == initial)
    }

    @Test func restoresSizeWhenRejectedSetterHasSideEffect() {
        let initial = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let requested = ResolvedFrame(x: 500, y: 300, width: 700, height: 500)
        var actual = initial

        let outcome = GeometryTransaction.applyFrame(
            initial: initial,
            requested: requested,
            setSize: { size in
                actual.size = size
                return size == initial.size
            },
            setPosition: {
                actual.origin = $0
                return true
            },
            readFrame: { actual }
        )

        #expect(outcome == .rejectedAndRestored)
        #expect(actual == initial)
    }

    @Test func successfulFrameMutationIsVerified() {
        let initial = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        var actual = initial
        let requested = ResolvedFrame(x: 50, y: 40, width: 900, height: 600)

        let outcome = GeometryTransaction.applyFrame(
            initial: initial,
            requested: requested,
            setSize: {
                actual.size = $0
                return true
            },
            setPosition: {
                actual.origin = $0
                return true
            },
            readFrame: { actual }
        )

        #expect(outcome == .applied)
        #expect(actual == requested.cgRect)
    }

    @Test func mutationTimeCheckBlocksOnlyMainWithDifferentOrUnknownFocus() {
        #expect(LiveWindowControl.geometryBlockedAtMutationTime(
            windowID: 10,
            focusedWindowID: 11,
            mainWindowID: 10
        ))
        #expect(LiveWindowControl.geometryBlockedAtMutationTime(
            windowID: 10,
            focusedWindowID: nil,
            mainWindowID: 10
        ))
        #expect(!LiveWindowControl.geometryBlockedAtMutationTime(
            windowID: 10,
            focusedWindowID: 10,
            mainWindowID: 10
        ))
        #expect(!LiveWindowControl.geometryBlockedAtMutationTime(
            windowID: 12,
            focusedWindowID: 11,
            mainWindowID: 10
        ))
    }
}

private extension ResolvedFrame {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
