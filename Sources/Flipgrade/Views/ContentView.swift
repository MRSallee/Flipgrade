import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: FlipSession

    var body: some View {
        Group {
            if session.photos.isEmpty {
                emptyState
            } else {
                CoverFlowView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .onAppear {
            session.openDefaultZionIfPresent()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            session.goPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            session.goNext()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "pP")) { _ in
            session.mark(.keeper)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { _ in
            session.mark(.archive)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "xX")) { _ in
            session.mark(.reject)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "uU")) { _ in
            session.mark(.undecided, advance: false)
            return .handled
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(session.statusMessage)
                .foregroundStyle(.secondary)
            Button("Open Folder…") {
                session.openFolder()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
