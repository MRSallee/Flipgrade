import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: FlipSession

    var body: some View {
        Group {
            if session.isShowingLibrary || session.photos.isEmpty {
                LibraryView()
            } else if session.isShowingGrade {
                GradeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CoverFlowView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .task {
            session.prepareLibrary()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard !session.isShowingLibrary, !session.isShowingGrade else { return .ignored }
            session.enterGrade()
            return .handled
        }
        .onKeyPress(.escape) {
            if session.isShowingGrade {
                if session.isPixelZoom {
                    session.togglePixelZoom()
                } else {
                    session.exitGrade()
                }
                return .handled
            }
            guard !session.isShowingLibrary, session.isPixelZoom else { return .ignored }
            session.togglePixelZoom()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard !session.isShowingLibrary, !session.isShowingGrade else { return .ignored }
            session.goPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !session.isShowingLibrary, !session.isShowingGrade else { return .ignored }
            session.goNext()
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !session.isShowingLibrary, !session.isShowingGrade else { return .ignored }
            session.goLayerDown()
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !session.isShowingLibrary, !session.isShowingGrade else { return .ignored }
            session.goLayerUp()
            return .handled
        }
        .onKeyPress(.space) {
            guard !session.isShowingLibrary else { return .ignored }
            // Space works in Flip and Grade (1:1 zoom).
            session.togglePixelZoom()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "0123")) { press in
            // Bare digits rate in Flip only — Grade uses 1–4 for HL ladder.
            guard !session.isShowingLibrary, !session.isShowingGrade,
                  let ch = press.characters.first, let n = Int(String(ch))
            else { return .ignored }
            session.rate(n)
            return .handled
        }
    }
}
