/// The mandatory modern discovery method.
public enum ServerDiscover: Method {
    public static let name = "server/discover"
    public typealias Parameters = ModernRequestParameters
    public typealias Result = DiscoverResult
}
