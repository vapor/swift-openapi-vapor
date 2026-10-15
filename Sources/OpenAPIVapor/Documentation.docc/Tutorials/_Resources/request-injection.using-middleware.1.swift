import OpenAPIRuntime
import OpenAPIVapor
import Vapor

// ...

let app = try await Vapor.Application()

let transport = VaporTransport(routesBuilder: app)

let handler = MyAPIProtocolImpl()

try handler.registerHandlers(on: transport, serverURL: Servers.server1())

// ...
