import Vapor

struct OpenAPIRequestInjectionMiddleware: Middleware {
    func respond(
        to request: Request,
        chainingTo responder: any Responder
    ) async throws -> Response {
        try await CurrentContext.$request.withValue(request) {
            try await responder.respond(to: request)
        }
    }
}
