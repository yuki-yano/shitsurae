import Foundation

public protocol RemoteCommandExecuting {
    func execute(_ request: AgentCommandRequest) -> CommandResult
}

extension AgentXPCClient: RemoteCommandExecuting {}

public struct RemoteCommandService {
    private let client: any RemoteCommandExecuting
    private let configDirectoryPathProvider: () -> String

    public init(
        configDirectoryPathProvider: @escaping () -> String = { ConfigPathResolver.configDirectoryURL().path }
    ) {
        self.init(
            client: AgentXPCClient(),
            configDirectoryPathProvider: configDirectoryPathProvider
        )
    }

    init(
        client: any RemoteCommandExecuting,
        configDirectoryPathProvider: @escaping () -> String = { ConfigPathResolver.configDirectoryURL().path }
    ) {
        self.client = client
        self.configDirectoryPathProvider = configDirectoryPathProvider
    }

    public func arrange(
        layoutName: String,
        spaceID: Int? = nil,
        dryRun: Bool,
        verbose: Bool,
        json: Bool,
        stateOnly: Bool = false
    ) -> CommandResult {
        client.execute(
            AgentCommandRequest(
                command: .arrange,
                json: json,
                dryRun: dryRun,
                verbose: verbose,
                layoutName: layoutName,
                spaceID: spaceID,
                slot: nil,
                includeAllSpaces: nil,
                x: nil,
                y: nil,
                width: nil,
                height: nil,
                configDirectoryPath: configDirectoryPathProvider(),
                stateOnly: stateOnly
            )
        )
    }
}
