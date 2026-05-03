import Vapor

struct OpenAPIRequestInjectionMiddleware: AsyncMiddleware {
  func respond(
    to request: Request,
    chainingTo responder: AsyncResponder
  ) async throws -> Response {

  }
}
