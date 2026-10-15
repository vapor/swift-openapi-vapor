# ``OpenAPIVapor``

Generate Swift client and server code from an OpenAPI document.

## Overview

### Request bodies

The request body is not collected up front: the `HTTPBody` your handler receives streams from
the connection and can be iterated once. A body that a middleware already collected is passed
through as is.

The body is limited by `maxBodySize`, the application's 16 KB default unless you set one:

```swift
let transport = VaporTransport(routesBuilder: app, maxBodySize: .specified("10mb"))
```

Going over it answers `413 Content Too Large` and closes the connection.

## Topics

### Tutorials
- <doc:RequestInjection>
