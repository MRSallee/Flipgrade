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
        .task {
            // Prefer .task over onAppear — more reliable for WindowGroup launch restore.
            session.restoreFolderIfPossible()
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
        .onKeyPress(.downArrow) {
            session.goLayerDown()
            return .handled
        }
        .onKeyPress(.upArrow) {
            session.goLayerUp()
            return .handled
        }
        .onKeyPress(.space) {
            session.togglePixelZoom()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "0")) { _ in
            session.rate(0)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1")) { _ in
            session.rate(1)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "2")) { _ in
            session.rate(2)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "3")) { _ in
            session.rate(3)
            return .handled
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.85))
            Text(session.statusMessage)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if session.isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            } else {
                Button("Open Folder…") {
                    session.openFolder()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
