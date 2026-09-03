import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Internal protocol for fetching OAuth discovery metadata.
protocol OAuthDiscoveryFetching: Sendable {
    var metadataDiscovery: any OAuthMetadataDiscovering { get }
    func fetchProtectedResourceMetadata(candidates: [URL], fallbackIssuer: URL?, session: URLSession) async throws -> OAuthProtectedResourceMetadata
    func fetchAuthorizationServerMetadata(candidates: [URL], session: URLSession) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata)
}

/// Stateless OAuth metadata fetcher.
///
/// Fetches Protected Resource Metadata (RFC 9728) and Authorization Server Metadata
/// (RFC 8414 / OIDC Discovery 1.0) from ordered candidate URL lists.
/// Cache management is the caller's responsibility.
struct OAuthDiscoveryClient: Sendable {
    let metadataDiscovery: any OAuthMetadataDiscovering
    let urlValidator: OAuthURLValidator

    init(
        metadataDiscovery: any OAuthMetadataDiscovering,
        urlValidator: OAuthURLValidator
    ) {
        self.metadataDiscovery = metadataDiscovery
        self.urlValidator = urlValidator
    }

    /// Fetches Protected Resource Metadata from the first candidate that returns a valid response.
    ///
    /// If all candidates fail and `fallbackIssuer` is provided, returns synthetic metadata
    /// using that issuer as the authorization server — for servers that do not expose a
    /// PRM document at any well-known path.
    func fetchProtectedResourceMetadata(
        candidates: [URL],
        fallbackIssuer: URL?,
        session: URLSession
    ) async throws -> OAuthProtectedResourceMetadata {
        let decoder = JSONDecoder()
        for url in candidates {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.accept)

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode)
                else {
                    continue
                }

                let metadata = try decoder.decode(OAuthProtectedResourceMetadata.self, from: data)
                guard !metadata.authorizationServers.isEmpty else { continue }
                return metadata
            } catch let error as OAuthAuthorizationError {
                throw error
            } catch {
                continue
            }
        }
        if let fallbackIssuer {
            return OAuthProtectedResourceMetadata(
                resource: nil,
                authorizationServers: [fallbackIssuer],
                scopesSupported: nil
            )
        }
        throw OAuthAuthorizationError.metadataDiscoveryFailed
    }

    /// Fetches Authorization Server Metadata from candidates, accepting only a response whose
    /// `issuer` matches the candidate URL (RFC 8414 §3). A metadata document from another
    /// issuer is never used as a fallback because doing so would let an untrusted discovery
    /// response redirect the authorization flow to a different server.
    func fetchAuthorizationServerMetadata(
        candidates: [URL],
        session: URLSession
    ) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        let decoder = JSONDecoder()
        var issuerMismatch: (expected: String, actual: String)?
        var issuerWasMissing = false

        for candidateServer in candidates {
            guard (try? urlValidator.validateAuthorizationServer(
                candidateServer, context: "Authorization server issuer")) != nil
            else {
                continue
            }
            if let host = URLComponents(url: candidateServer, resolvingAgainstBaseURL: false)?
                .host?.lowercased(), urlValidator.isPrivateIPHost(host)
            {
                continue
            }

            for metadataURL in metadataDiscovery.authorizationServerMetadataURLs(
                for: candidateServer)
            {
                var request = URLRequest(url: metadataURL)
                request.httpMethod = "GET"
                request.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.accept)

                do {
                    let (data, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                        (200..<300).contains(httpResponse.statusCode)
                    else {
                        continue
                    }

                    let asMetadata = try decoder.decode(
                        OAuthAuthorizationServerMetadata.self, from: data)

                    // RFC 8414 requires exact issuer identifier matching.
                    guard let issuer = asMetadata.issuer else {
                        issuerWasMissing = true
                        continue
                    }
                    if issuer.absoluteString == candidateServer.absoluteString {
                        return (server: candidateServer, metadata: asMetadata)
                    }
                    if issuerMismatch == nil {
                        issuerMismatch = (
                            expected: candidateServer.absoluteString,
                            actual: issuer.absoluteString
                        )
                    }
                } catch {
                    continue
                }
            }
        }

        if let issuerMismatch {
            throw OAuthAuthorizationError.authorizationServerIssuerMismatch(
                expected: issuerMismatch.expected,
                actual: issuerMismatch.actual
            )
        }
        if issuerWasMissing {
            throw OAuthAuthorizationError.authorizationServerMetadataMissingIssuer
        }
        throw OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed
    }
}

extension OAuthDiscoveryClient: OAuthDiscoveryFetching {}
