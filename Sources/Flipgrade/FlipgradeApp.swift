import SwiftUI

@main
struct FlipgradeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = FlipSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    session.openFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            Form {
                Text("Phase 0 spike — cull speed only. Grade tools come later.")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 360)
            .padding()
        }
    }
}
