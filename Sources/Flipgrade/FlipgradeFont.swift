import AppKit
import CoreText
import SwiftUI

enum FlipgradeFont {
    /// UI chrome type — Golos Text Regular 16pt, 150% line height.
    static let size: CGFloat = 16
    /// Folder title in the top-left chrome.
    static let folderSize: CGFloat = 20
    static let lineHeight: CGFloat = size * 1.5
    static let folderLineHeight: CGFloat = folderSize * 1.5
    /// Extra spacing SwiftUI adds between lines (on top of the font’s intrinsic leading).
    static var lineSpacing: CGFloat {
        max(0, lineHeight - nativeLineHeight(size: size))
    }
    static var folderLineSpacing: CGFloat {
        max(0, folderLineHeight - nativeLineHeight(size: folderSize))
    }
    /// Gap between stacked single-line chrome rows (baseline-to-baseline ≈ lineHeight).
    static var stackSpacing: CGFloat {
        max(0, lineHeight - size)
    }

    static var ui: Font {
        .custom(familyName, size: size).weight(.regular)
    }

    static var folder: Font {
        .custom(familyName, size: folderSize).weight(.regular)
    }

    private static func nativeLineHeight(size: CGFloat) -> CGFloat {
        let face = NSFont(name: "GolosText-Regular", size: size)
            ?? NSFont(name: familyName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .regular)
        return ceil(face.ascender - face.descender + face.leading)
    }

    private static let familyName = "Golos Text"

    /// Register the bundled variable font (safe to call more than once).
    ///
    /// Never touch `Bundle.module` here — in a packaged `.app` SPM's resource-bundle
    /// lookup asserts and kills launch (`NSBundle.module` / `Flipgrade_Flipgrade`).
    static func registerBundledFonts() {
        let name = "GolosText-VariableFont_wght"
        for bundle in fontSearchBundles() {
            if let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? bundle.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                return
            }
        }
    }

    /// App Resources first; then an on-disk SPM resource bundle if present (debug `swift run`).
    private static func fontSearchBundles() -> [Bundle] {
        var bundles: [Bundle] = [.main]
        let spmName = "Flipgrade_Flipgrade.bundle"
        let neighbors: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(spmName),
            Bundle.main.bundleURL.appendingPathComponent(spmName),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(spmName)
        ]
        for case let url? in neighbors {
            if let bundle = Bundle(url: url), !bundles.contains(where: { $0.bundlePath == bundle.bundlePath }) {
                bundles.append(bundle)
            }
        }
        return bundles
    }
}
