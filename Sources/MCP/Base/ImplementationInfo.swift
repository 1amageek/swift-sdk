import Foundation

/// Identity metadata carried by modern request and result metadata.
public struct ImplementationInfo: Hashable, Codable, Sendable {
    public let name: String
    public let version: String
    public let title: String?
    public let description: String?
    public let websiteUrl: String?
    public let icons: [Icon]?

    public init(
        name: String,
        version: String,
        title: String? = nil,
        description: String? = nil,
        websiteUrl: String? = nil,
        icons: [Icon]? = nil
    ) {
        self.name = name
        self.version = version
        self.title = title
        self.description = description
        self.websiteUrl = websiteUrl
        self.icons = icons
    }
}
