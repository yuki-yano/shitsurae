import Foundation

enum ArrangeCommandOutputRenderer {
    static func dryRun(_ plan: ArrangeDryRunJSON) -> String {
        [
            "layout: \(plan.layout)",
            "spacesMode: \(plan.spacesMode.rawValue)",
            "planCount: \(plan.plan.count)",
            "skippedCount: \(plan.skipped.count)",
            "warningCount: \(plan.warnings.count)",
        ].joined(separator: "\n") + "\n"
    }

    static func execution(_ execution: ArrangeExecutionJSON) -> String {
        [
            "layout: \(execution.layout)",
            "result: \(execution.result)",
            "exitCode: \(execution.exitCode)",
            "hardErrors: \(execution.hardErrors.count)",
            "softErrors: \(execution.softErrors.count)",
            "skipped: \(execution.skipped.count)",
            "warnings: \(execution.warnings.count)",
        ].joined(separator: "\n") + "\n"
    }

    static func verbose(_ execution: ArrangeExecutionJSON) -> String {
        var lines: [String] = []
        for error in execution.hardErrors {
            lines.append("hardError code=\(error.code) message=\(error.message)")
        }
        for error in execution.softErrors {
            lines.append("softError code=\(error.code) message=\(error.message)")
        }
        for warning in execution.warnings {
            lines.append("warning code=\(warning.code) detail=\(warning.detail)")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
