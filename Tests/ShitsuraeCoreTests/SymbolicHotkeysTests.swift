import Testing
@testable import ShitsuraeCore

@Suite("SymbolicHotKeyController")
struct SymbolicHotkeysTests {
    @Test func reportsAppliedOnlyWhenEveryMutationSucceeds() {
        var calls: [(Int32, Bool)] = []

        let result = SymbolicHotKeyController.apply(
            isEnabled: false,
            hotKeys: SymbolicHotKeyController.commandTabGroup
        ) { hotKey, enabled in
            calls.append((hotKey, enabled))
            return 0
        }

        #expect(result == .applied)
        #expect(calls.map(\.0) == [1, 2])
        #expect(calls.allSatisfy { !$0.1 })
    }

    @Test func rollsBackTheWholeGroupAfterPartialFailure() {
        var calls: [(Int32, Bool)] = []

        let result = SymbolicHotKeyController.apply(
            isEnabled: false,
            hotKeys: SymbolicHotKeyController.commandTabGroup
        ) { hotKey, enabled in
            calls.append((hotKey, enabled))
            return !enabled && hotKey == 2 ? 1 : 0
        }

        #expect(result == .rolledBack)
        #expect(calls.map(\.0) == [1, 2, 1, 2])
        #expect(calls.map(\.1) == [false, false, true, true])
    }

    @Test func reportsIndeterminateWhenCompensationAlsoFails() {
        let result = SymbolicHotKeyController.apply(
            isEnabled: false,
            hotKeys: SymbolicHotKeyController.commandTabGroup
        ) { hotKey, enabled in
            if !enabled && hotKey == 2 { return 1 }
            if enabled && hotKey == 1 { return 1 }
            return 0
        }

        #expect(result == .indeterminate)
    }
}
