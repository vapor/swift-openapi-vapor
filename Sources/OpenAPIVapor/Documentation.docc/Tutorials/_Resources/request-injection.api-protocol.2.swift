import Logging
import OpenAPIVapor

struct MyAPIProtocolImpl: APIProtocol {
    func myOpenAPIEndpointFunction() async throws -> Operations.myOperation.Output {
        /// Use `CurrentContext.request` as if this is a normal Vapor endpoint function
        if let request = CurrentContext.request {
            Logger.current.notice(
                "Got a request!",
                metadata: [
                    "request": .stringConvertible(request)
                ]
            )
        }
    }
}
