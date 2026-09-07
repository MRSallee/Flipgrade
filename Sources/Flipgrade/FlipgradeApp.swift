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

            CommandMenu("Rate") {
                Button("Clear (0★)") { session.rate(0) }
                    .keyboardShortcut("0", modifiers: [])
                Button("1★") { session.rate(1) }
                    .keyboardShortcut("1", modifiers: [])
                Button("2★") { session.rate(2) }
                    .keyboardShortcut("2", modifiers: [])
                Button("3★") { session.rate(3) }
                    .keyboardShortcut("3", modifiers: [])
            }

            CommandMenu("Layer") {
                Button("All Photos") {
                    session.setLayer(.all)
                }
                Button("Stricter (↓)") {
                    session.goLayerDown()
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                Button("Looser (↑)") {
                    session.goLayerUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [])
            }
        }

        Settings {
            Form {
                Text("Flipgrade — 0–3★ cull layers. Grade tools come later.")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 360)
            .padding()
        }
    }
}
