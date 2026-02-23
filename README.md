# Swift OpenAPI Vapor

This package provides Vapor Bindings for the [OpenAPI generator](https://github.com/apple/swift-openapi-generator).

## Usage

In `entrypoint.swift` add:

```swift
// Create a Vapor OpenAPI Transport using your application.
let transport = VaporTransport(routesBuilder: app)

// Create an instance of your handler type that conforms the generated protocol
// defining your service API.
let handler = MyServiceAPIImpl()

// Call the generated function on your implementation to add its request
// handlers to the app.
try handler.registerHandlers(on: transport)
```

## Documentation

To get started, check out the full [documentation][docs-generator], which contains step-by-step tutorials!

Additionally, see the [request injection tutorial][request-injection-tutorial] to learn how you can use [swift-dependencies] to inject `Request` into `APIProtocol`:

```swift
struct MyAPIProtocolImpl: APIProtocol {
    @Dependency(\.request) var request


    func myOpenAPIEndpointFunction() async throws -> Operations.myOperation.Output {
        /// Use `request` as if this is a normal Vapor endpoint function
        request.logger.notice(
            "Got a request!",
            metadata: [
                "request": .stringConvertible(request)
            ]
        )
    }
}
```

[docs-generator]: https://swiftpackageindex.com/apple/swift-openapi-generator/documentation
[swift-dependencies]: https://github.com/pointfreeco/swift-dependencies
[request-injection-tutorial]: https://swiftpackageindex.com/vapor/swift-openapi-vapor/1.0.1/tutorials/swift-openapi-vapor/requestinjection
