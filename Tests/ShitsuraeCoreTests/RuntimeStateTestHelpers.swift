import ShitsuraeCore

/// Single-display test conveniences mirroring the pre-v5 accessors: most
/// engine tests run with exactly one display, whose workspace is the first
/// (and only) activeWorkspaces element.
extension RuntimeState {
    var activeLayoutName: String? { activeWorkspaces.first?.layoutName }

    var primaryActiveSpaceID: Int? { activeWorkspaces.first?.spaceID }

    func activeSpaceID(displayID: String) -> Int? {
        activeWorkspace(displayID: displayID)?.spaceID
    }

    var firstPendingVisibilityConvergence: PendingVisibilityConvergence? {
        get { pendingVisibilityConvergences.first }
        set { pendingVisibilityConvergences = newValue.map { [$0] } ?? [] }
    }
}
