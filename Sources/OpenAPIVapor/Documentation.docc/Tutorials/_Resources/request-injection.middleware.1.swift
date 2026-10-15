import Vapor

struct OpenAPIRequestInjectionMiddleware: Middleware {
    func respond(
        to request: Request,
        chainingTo responder: any Responder
    ) async throws -> Response {

    }
}
