import Library
import MacLibrary
import SwiftUI

struct Application: App {
    @NSApplicationDelegateAdaptor private var appDelegate: StandaloneApplicationDelegate

    init() {}

    var body: some Scene {
        MacApplication(applicationState: appDelegate.applicationState)
    }
}

@main
enum AirlockApplication {
    @MainActor static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        let qualification: Bool
        switch arguments.first {
        case "--airlock-control":
            qualification = false
        case "--airlock-acceptance":
            #if AIRLOCK_ACCEPTANCE
                qualification = true
            #else
                FileHandle.standardError.write(Data("This action needs an Airlock qualification build.\n".utf8))
                exit(EXIT_FAILURE)
            #endif
        default:
            Application.main()
            return
        }
        Variant.useSystemExtension = true
        Task { @MainActor in
            do {
                try await AirlockAcceptance.run(Array(arguments.dropFirst()), qualification: qualification)
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}
