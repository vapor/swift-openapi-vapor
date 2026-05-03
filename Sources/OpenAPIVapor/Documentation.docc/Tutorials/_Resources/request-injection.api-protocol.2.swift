import OpenAPIVapor

struct MyAPIProtocolImpl: APIProtocol {
  func myOpenAPIEndpointFunction() async throws -> Operations.myOperation.Output {
    /// Use `CurrentContext.request` as if this is a normal Vapor endpoint function
    CurrentContext.request?.logger.notice(
      "Got a request!",
      metadata: [
        "request": .stringConvertible(CurrentContext.request)
      ]
    )
  }
}
