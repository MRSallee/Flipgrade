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

                Button("Library") {
                    session.showLibrary()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(session.isShowingLibrary)

                Divider()

                Button("Grade") {
                    session.enterGrade()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(session.isShowingLibrary || session.isShowingGrade || session.currentPhoto == nil)
            }

            CommandMenu("Rate") {
                // ⌘-number so bare 1–4 stay free for Grade HL ladder.
                Button("Clear (0★)") { session.rate(0) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("1★") { session.rate(1) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("2★") { session.rate(2) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("3★") { session.rate(3) }
                    .keyboardShortcut("3", modifiers: .command)
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
                Text("Flipgrade v0.2 — cull Flip + Grade (WB / tone / H-S).")
                    .foregroundStyle(.secondary)
                Picker("Tone mode", selection: Binding(
                    get: { session.developColorMode },
                    set: { session.developColorMode = $0 }
                )) {
                    Text("LAB").tag(DevelopColorMode.lab)
                    Text("RGB").tag(DevelopColorMode.rgb)
                }
                Slider(
                    value: Binding(
                        get: { session.developBaseBoost },
                        set: { session.developBaseBoost = $0 }
                    ),
                    in: DevelopPrefs.baseBoostRange
                ) {
                    Text("Base")
                } minimumValueLabel: {
                    Text("Soft")
                } maximumValueLabel: {
                    Text("Punch")
                }
                Text("CIRAW tone curve. Default \(Int(DevelopPrefs.defaultBaseBoost * 100)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 360)
            .padding()
        }
    }
}
