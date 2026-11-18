import Library
import MacLibrary
import SwiftUI

#if !AIRLOCK_ACCEPTANCE
@main
#endif
struct Application: App {
    @NSApplicationDelegateAdaptor private var appDelegate: StandaloneApplicationDelegate

    init() {}

    var body: some Scene {
        MacApplication(applicationState: appDelegate.applicationState)
    }
}

#if AIRLOCK_ACCEPTANCE
    @main
    enum AcceptanceApplication {
        @MainActor static func main() {
            let arguments = CommandLine.arguments.dropFirst()
            guard arguments.first == "--airlock-acceptance" else {
                Application.main()
                return
            }
            Variant.useSystemExtension = true
            Task { @MainActor in
                do {
                    try await AirlockAcceptance.run(Array(arguments.dropFirst()))
                    exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
            dispatchMain()
        }
    }
#endif
