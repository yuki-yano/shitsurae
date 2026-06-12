import CoreGraphics
import Foundation

public struct ArrangeStep: Equatable, Sendable {
    public let spaceID: Int
    public let definition: WindowDefinition
    public let resolvedFrame: ResolvedFrame
}

public struct ArrangePlan: Equatable, Sendable {
    public let layoutName: String
    public let planItems: [PlanItem]
    public let steps: [ArrangeStep]
    public let skipped: [SkippedItem]
    public let warnings: [WarningItem]
}

/// Pure arrange planning: which windows to launch / wait for / place where.
/// dry-run and live execution share one plan builder (v1 mixed both into a
/// single loop with flags; v2 derives the dry-run report from the plan).
public enum ArrangePlanner {
    public static func buildPlan(
        layoutName: String,
        layout: LayoutDefinition,
        spaceID: Int?,
        config: ShitsuraeConfig,
        hostDisplay: DisplayInfo,
        displays: [DisplayInfo],
        currentWindows: [WindowSnapshot]?
    ) -> ArrangePlan {
        var planItems: [PlanItem] = []
        var steps: [ArrangeStep] = []
        var skipped: [SkippedItem] = []
        var warnings: [WarningItem] = []
        var registeredSlots = Set<Int>()

        // All spaces of a layout share the host display in v2.0 (validated at
        // config load). The placement basis is its visible frame in CG coords.
        let basis = VisibilityPlanner.coordinateRect(hostDisplay.visibleFrame, displays: displays)

        for space in layout.spaces {
            if let spaceID, space.spaceID != spaceID {
                continue
            }

            for definition in space.windows {
                let launch = definition.launch ?? true

                if PolicyEngine.matchesIgnoreRule(windowDefinition: definition, rules: config.ignore?.apply) {
                    skipped.append(
                        SkippedItem(
                            spaceID: space.spaceID,
                            slot: definition.slot,
                            reason: "ignoreApply",
                            detail: "matched ignore.apply rule"
                        )
                    )
                    warnings.append(
                        WarningItem(
                            code: "ignore.apply.matched",
                            detail: "slot \(definition.slot) skipped by ignore.apply"
                        )
                    )
                    continue
                }

                guard let resolvedFrame = try? LengthParser.resolveFrame(
                    definition.frame,
                    basis: basis,
                    scale: hostDisplay.scale
                ) else {
                    skipped.append(
                        SkippedItem(
                            spaceID: space.spaceID,
                            slot: definition.slot,
                            reason: "frameUnresolvable",
                            detail: "frame could not be resolved for the host display"
                        )
                    )
                    continue
                }

                if launch {
                    planItems.append(
                        PlanItem(
                            spaceID: space.spaceID,
                            slot: definition.slot,
                            bundleID: definition.match.bundleID,
                            action: "launch",
                            frame: nil,
                            launch: true
                        )
                    )
                }

                if let currentWindows {
                    let nonFullscreen = currentWindows.filter { !$0.isFullscreen }
                    let candidates = WindowRegistry.sortedCandidates(rule: definition.match, pool: nonFullscreen)
                    if candidates.isEmpty {
                        skipped.append(
                            SkippedItem(
                                spaceID: space.spaceID,
                                slot: definition.slot,
                                reason: "noWindowMatched",
                                detail: "no current window matched"
                            )
                        )
                    }
                }

                planItems.append(
                    PlanItem(
                        spaceID: space.spaceID,
                        slot: definition.slot,
                        bundleID: definition.match.bundleID,
                        action: "waitWindow",
                        frame: nil,
                        launch: launch
                    )
                )
                planItems.append(
                    PlanItem(
                        spaceID: space.spaceID,
                        slot: definition.slot,
                        bundleID: definition.match.bundleID,
                        action: "setFrame",
                        frame: resolvedFrame,
                        launch: launch
                    )
                )
                planItems.append(
                    PlanItem(
                        spaceID: space.spaceID,
                        slot: definition.slot,
                        bundleID: definition.match.bundleID,
                        action: "registerSlot",
                        frame: nil,
                        launch: launch
                    )
                )

                steps.append(
                    ArrangeStep(
                        spaceID: space.spaceID,
                        definition: definition,
                        resolvedFrame: resolvedFrame
                    )
                )
                registeredSlots.insert(definition.slot)
            }
        }

        if let initialSlot = layout.initialFocus?.slot {
            if registeredSlots.contains(initialSlot) {
                planItems.append(
                    PlanItem(
                        spaceID: layout.spaces.first?.spaceID ?? 1,
                        slot: initialSlot,
                        bundleID: "",
                        action: "focusInitial",
                        frame: nil,
                        launch: false
                    )
                )
            } else {
                warnings.append(
                    WarningItem(
                        code: "initial.focus.unavailable",
                        detail: "slot \(initialSlot) was not registered"
                    )
                )
            }
        }

        return ArrangePlan(
            layoutName: layoutName,
            planItems: planItems,
            steps: steps,
            skipped: skipped,
            warnings: warnings
        )
    }
}
