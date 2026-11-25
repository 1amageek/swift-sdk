import Foundation

/// A resource namespace that an extension module mounts on a ``Server``.
///
/// For every `resources/read` request the server asks its mounted namespaces
/// in mount order before the application's `resources/read` handler. A
/// namespace returns `nil` for a URI it does not own; the first non-nil result
/// is the complete response. A thrown error is the response error.
package struct ResourceNamespace: Sendable {
    let read: @Sendable (ReadResource.Parameters) async throws -> ReadResource.Result?

    package init(
        read: @escaping @Sendable (ReadResource.Parameters) async throws -> ReadResource.Result?
    ) {
        self.read = read
    }
}

extension Server {
    /// Mounts a resource namespace consulted before the application's
    /// `resources/read` handler in both protocol eras.
    package func mount(_ namespace: ResourceNamespace) {
        resourceNamespaces.append(namespace)
    }

    /// Reads `parameters` from the mounted namespaces, in mount order.
    ///
    /// - Returns: The first owned result, or `nil` when no namespace owns the URI.
    static func readMountedResource(
        _ parameters: ReadResource.Parameters,
        from namespaces: [ResourceNamespace]
    ) async throws -> ReadResource.Result? {
        for namespace in namespaces {
            if let result = try await namespace.read(parameters) {
                return result
            }
        }
        return nil
    }
}

/// The legacy-era `resources/read` handler used while namespaces are mounted.
///
/// It owns no state beyond an immutable snapshot of the namespaces and the
/// application handler taken when the request is dispatched.
final class MountedResourceReadHandler: RequestHandlerBox, @unchecked Sendable {
    // Immutable after initialization; @unchecked Sendable follows the
    // RequestHandlerBox class contract used by every request handler box.
    private let namespaces: [ResourceNamespace]
    private let applicationHandler: RequestHandlerBox?

    init(namespaces: [ResourceNamespace], applicationHandler: RequestHandlerBox?) {
        self.namespaces = namespaces
        self.applicationHandler = applicationHandler
        super.init()
    }

    override func callAsFunction(_ request: AnyRequest) async throws -> AnyResponse {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let typedRequest = try decoder.decode(
            Request<ReadResource>.self,
            from: encoder.encode(request)
        )
        if let result = try await Server.readMountedResource(
            typedRequest.params,
            from: namespaces
        ) {
            let value = try decoder.decode(Value.self, from: encoder.encode(result))
            return Response(id: request.id, result: value)
        }
        guard let applicationHandler else {
            return Response(
                id: request.id,
                error: MCPError.resourceNotFound(uri: typedRequest.params.uri)
            )
        }
        return try await applicationHandler(request)
    }
}
