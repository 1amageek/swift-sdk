import Foundation
import Testing

@testable import MCP

@Suite("OAuth Token Storage Concurrency")
struct OAuthTokenStorageConcurrencyTests {
    @Test("InMemoryTokenStorage serializes concurrent load save and clear")
    func concurrentLoadSaveAndClearAreSafe() async {
        let storage = InMemoryTokenStorage()
        let tokens = (0..<16).map { index in
            OAuthAccessToken(
                value: "token-\(index)",
                tokenType: "Bearer",
                expiresAt: nil,
                scopes: ["scope-\(index)"],
                authorizationServer: nil,
                refreshToken: nil
            )
        }
        let expectedValues = Set(tokens.map(\.value))

        let observedValues = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for operation in 0..<256 {
                group.addTask {
                    switch operation % 4 {
                    case 0:
                        storage.save(tokens[operation % tokens.count])
                        return storage.load()?.value
                    case 1:
                        return storage.load()?.value
                    case 2:
                        storage.clear()
                        return storage.load()?.value
                    default:
                        storage.save(tokens[operation % tokens.count])
                        storage.clear()
                        return storage.load()?.value
                    }
                }
            }

            var values: [String?] = []
            values.reserveCapacity(256)
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(observedValues.count == 256)
        #expect(observedValues.allSatisfy { value in
            guard let value else { return true }
            return expectedValues.contains(value)
        })

        storage.clear()
        #expect(storage.load() == nil)
    }
}
