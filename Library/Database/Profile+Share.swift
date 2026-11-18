import Foundation
import Libbox

public extension Profile {
    var shareLink: URL {
        Self.remoteImportLink(name: name, remoteURL: remoteURL!)
    }

    static func remoteImportLink(name: String, remoteURL: String) -> URL {
        let url = URL(string: LibboxGenerateRemoteProfileImportLink(name, remoteURL))!
        // Both the registered scheme and this value come from the app build settings.
        return AppLinks.replacingScheme(in: url, with: AppConfiguration.urlScheme)!
    }
}
