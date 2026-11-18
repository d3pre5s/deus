import Foundation

public enum AppLinks {
    public static func replacingScheme(in url: URL, with scheme: String) -> URL? {
        guard scheme.range(of: #"\A[A-Za-z][A-Za-z0-9+.-]*\z"#, options: .regularExpression) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return nil }
        components.scheme = scheme
        return components.url
    }
}
