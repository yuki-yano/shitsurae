import Foundation
import ShitsuraeCore

let logger = ShitsuraeLogger()
logger.log(event: "agent.start")

let server = AgentXPCServer()
server.start()
RunLoop.main.run()
