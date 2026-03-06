import Foundation

public struct ArrangeQualityMeasurement: Codable, Equatable {
    public let slot: Int
    public let expectedFrame: ResolvedFrame
    public let actualFrame: ResolvedFrame

    public init(slot: Int, expectedFrame: ResolvedFrame, actualFrame: ResolvedFrame) {
        self.slot = slot
        self.expectedFrame = expectedFrame
        self.actualFrame = actualFrame
    }

    public func maxFrameDiffPt() -> Double {
        max(
            abs(expectedFrame.x - actualFrame.x),
            abs(expectedFrame.y - actualFrame.y),
            abs(expectedFrame.width - actualFrame.width),
            abs(expectedFrame.height - actualFrame.height)
        )
    }

    public func matched(within tolerancePt: Double) -> Bool {
        maxFrameDiffPt() <= tolerancePt
    }
}

public struct ArrangeQualityReport: Codable, Equatable {
    public let layout: String
    public let executedAt: String
    public let expectedSlots: Int
    public let matchedSlots: Int
    public let slotMatchRate: Double
    public let frameDiffMaxPt: Double
    public let displayMismatchExpected: Int
    public let displayMismatchActual: Int

    public init(
        layout: String,
        executedAt: String,
        expectedSlots: Int,
        matchedSlots: Int,
        slotMatchRate: Double,
        frameDiffMaxPt: Double,
        displayMismatchExpected: Int,
        displayMismatchActual: Int
    ) {
        self.layout = layout
        self.executedAt = executedAt
        self.expectedSlots = expectedSlots
        self.matchedSlots = matchedSlots
        self.slotMatchRate = slotMatchRate
        self.frameDiffMaxPt = frameDiffMaxPt
        self.displayMismatchExpected = displayMismatchExpected
        self.displayMismatchActual = displayMismatchActual
    }
}

public enum ArrangeQualityEvaluator {
    public static func buildReport(
        layout: String,
        execution: ArrangeExecutionJSON,
        measurements: [ArrangeQualityMeasurement],
        displayMismatchActual: Int,
        executedAt: String? = nil,
        frameTolerancePt: Double = 2.0
    ) -> ArrangeQualityReport {
        let expectedSlots = measurements.count
        let matchedSlots = measurements.filter { $0.matched(within: frameTolerancePt) }.count
        let slotMatchRate: Double
        if expectedSlots == 0 {
            slotMatchRate = 0
        } else {
            slotMatchRate = (Double(matchedSlots) / Double(expectedSlots)) * 100.0
        }

        let frameDiffMaxPt = measurements.map { $0.maxFrameDiffPt() }.max() ?? 0
        let displayMismatchExpected = execution.skipped.filter { $0.reason == "displayMismatch" }.count
        let timestamp = executedAt ?? nowRFC3339UTC()

        return ArrangeQualityReport(
            layout: layout,
            executedAt: timestamp,
            expectedSlots: expectedSlots,
            matchedSlots: matchedSlots,
            slotMatchRate: rounded(slotMatchRate),
            frameDiffMaxPt: rounded(frameDiffMaxPt),
            displayMismatchExpected: displayMismatchExpected,
            displayMismatchActual: displayMismatchActual
        )
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private static func nowRFC3339UTC() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}
