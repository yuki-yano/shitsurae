import Foundation

struct LockedRuntimeStateMutationContext {
    let persistedState: RuntimeState
    let loadedConfig: LoadedConfig?
    let readContext: RuntimeStateReadContext

    var state: RuntimeState {
        readContext.state
    }
}

enum LockedRuntimeStateMutationPreparation {
    case ready(LockedRuntimeStateMutationContext)
    case result(CommandResult)
}
