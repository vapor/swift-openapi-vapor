import Vapor

struct OpenAPIRequestInjectionMiddleware: AsyncMiddleware {
  func respond(
    to request: Request,
    chainingTo responder: AsyncResponder
  ) async throws -> Response {
    try await CurrentContext.$request.withValue(request) {
      try await responder.respond(to: request)
    }
  }
}
