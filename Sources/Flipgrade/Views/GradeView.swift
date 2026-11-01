import AppKit
import CoreImage
import SwiftUI

/// Dual-demosaic ladder stages — freeze knobs, inspect which step loses ACR detail.
private enum HSDebugStage: Int, CaseIterable, Identifiable {
    case punch = 1
    case recover = 2
    case blend = 3
    case final = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .punch: return "1 Punch"
        case .recover: return "2 Recover"
        case .blend: return "3 Blend"
        case .final: return "4 Final"
        }
    }

    func hint(for kind: HSLadderKind) -> String {
        switch (kind, self) {
        case (.highlights, .punch): return "Base CIRAW — clipped like H0?"
        case (.highlights, .recover): return "Low-boost CIRAW — hat/lamp detail?"
        case (.highlights, .blend): return "Masked merge — mids + detail?"
        case (.highlights, .final): return "After post-tone — crush/posterize?"
        case (.shadows, .punch): return "Base CIRAW — doorway crushed?"
        case (.shadows, .recover): return "CIRAW shadowOpen — RAW toe detail?"
        case (.shadows, .blend): return "Masked merge — open toe, keep mids?"
        case (.shadows, .final): return "After post-tone — flat/muddy?"
        }
    }
}

private enum HSLadderKind {
    case highlights
    case shadows

    var title: String {
        switch self {
        case .highlights: return "HL ladder"
        case .shadows: return "SH ladder"
        }
    }

    var dumpFolder: String {
        switch self {
        case .highlights: return "Flipgrade-HL-Debug"
        case .shadows: return "Flipgrade-SH-Debug"
        }
    }
}

/// Single-image Grade workspace: large fit image + slim right inspector.
/// Space → 1:1 with the inspector floating over the image.
struct GradeView: View {
    @EnvironmentObject private var session: FlipSession
    @ObservedObject private var previews = PreviewService.shared
    @State private var zoomMouseFraction = CGPoint(x: 0.5, y: 0.5)
    @State private var developedFit: NSImage?
    @State private var developedFull: NSImage?
    @State private var renderGeneration: UInt64 = 0
    @State private var isRendering = false
    @State private var pendingFull = false
    @State private var pendingRender = false
    @State private var cachedFitCI: CIImage?
    @State private var cachedFitKey = ""
    @State private var cachedFullCI: CIImage?
    @State private var cachedFullKey = ""
    @State private var fullUpgradeTask: Task<Void, Never>?

    /// Dual-demosaic diagnostic ladders (−H and/or +S).
    @State private var hsDebugStage: HSDebugStage = .final
    @State private var ladderFocus: HSLadderKind = .highlights
    @State private var hlPunchImage: NSImage?
    @State private var hlRecoverImage: NSImage?
    @State private var hlBlendImage: NSImage?
    @State private var hlLadderActive = false
    @State private var shPunchImage: NSImage?
    @State private var shRecoverImage: NSImage?
    @State private var shBlendImage: NSImage?
    @State private var shLadderActive = false
    @State private var ladderDumpStatus: String?

    /// Interactive scrub long-edge — keeps slider feedback snappy.
    private let scrubMaxPixels: CGFloat = 1280
    private let inspectorWidth: CGFloat = 220

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if session.isPixelZoom {
                    zoomLayer(size: geo.size)
                    inspectorCard
                        .padding(.trailing, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                } else {
                    HStack(spacing: 20) {
                        fitImageStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        inspectorCard
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay {
                if session.isPixelZoom {
                    ZoomMouseTracker(
                        syncToken: zoomSyncToken,
                        onFraction: { next in
                            if abs(next.x - zoomMouseFraction.x) > 0.0005
                                || abs(next.y - zoomMouseFraction.y) > 0.0005 {
                                zoomMouseFraction = next
                            }
                        }
                    )
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
            guard hlLadderActive || shLadderActive,
                  let ch = press.characters.first, let n = Int(String(ch)),
                  let stage = HSDebugStage(rawValue: n)
            else { return .ignored }
            hsDebugStage = stage
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "dD")) { _ in
            guard hlLadderActive || shLadderActive else { return .ignored }
            dumpHSDebugStages()
            return .handled
        }
        .onAppear {
            if let photo = session.currentPhoto {
                session.refreshAsShotWhiteBalance(for: photo)
            }
            enqueueRender(wantFull: false)
        }
        .onChange(of: session.gradeRecipe) { _, recipe in
            if recipe.highlights >= -0.0001 {
                clearHLLadder()
            }
            if recipe.shadows <= 0.0001 {
                clearSHLadder()
            }
            if recipe.shadows > 0.0001 {
                ladderFocus = .shadows
            } else if recipe.highlights < -0.0001 {
                ladderFocus = .highlights
            }
            // Dual-demosaic change — never keep a stale punch CI.
            cachedFitCI = nil
            cachedFitKey = ""
            cachedFullCI = nil
            cachedFullKey = ""
            // Always scrub at proxy size; upgrade to full after drag settles.
            enqueueRender(wantFull: false)
            if session.isPixelZoom {
                scheduleFullUpgrade()
            }
        }
        .onChange(of: session.developColorMode) { _, _ in
            enqueueRender(wantFull: false)
            if session.isPixelZoom {
                scheduleFullUpgrade()
            }
        }
        .onChange(of: session.developBaseBoost) { _, _ in
            cachedFitCI = nil
            cachedFitKey = ""
            cachedFullCI = nil
            cachedFullKey = ""
            enqueueRender(wantFull: false)
            if session.isPixelZoom {
                scheduleFullUpgrade()
            }
        }
        .onChange(of: session.currentPhoto?.id) { _, _ in
            developedFit = nil
            developedFull = nil
            cachedFitCI = nil
            cachedFitKey = ""
            cachedFullCI = nil
            cachedFullKey = ""
            clearHLLadder()
            clearSHLadder()
            if let photo = session.currentPhoto {
                session.refreshAsShotWhiteBalance(for: photo)
            }
            enqueueRender(wantFull: session.isPixelZoom)
        }
        .onChange(of: session.isPixelZoom) { _, zoomed in
            if zoomed, let photo = session.currentPhoto {
                enqueueRender(wantFull: true)
                previews.requestFullResolution(photo)
            }
        }
        .onChange(of: previews.viewportRevision) { _, _ in
            cachedFitCI = nil
            cachedFitKey = ""
            enqueueRender(wantFull: false)
        }
        .onChange(of: previews.fullResolutionRevision) { _, _ in
            cachedFullCI = nil
            cachedFullKey = ""
            if session.isPixelZoom { enqueueRender(wantFull: true) }
        }
    }

    private var zoomSyncToken: String {
        let id = session.currentPhoto?.id ?? ""
        return "grade-\(id)-\(session.isPixelZoom)-\(previews.fullResolutionRevision)-\(renderGeneration)"
    }

    private var fitImageStage: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image = displayedFitImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
    }

    private var displayedFitImage: NSImage? {
        if hsDebugStage != .final {
            switch focusedLadderImages {
            case let (punch?, _, _) where hsDebugStage == .punch:
                return punch
            case let (_, recover?, _) where hsDebugStage == .recover:
                return recover
            case let (_, _, blend?) where hsDebugStage == .blend:
                return blend
            default:
                break
            }
        }
        return developedFit ?? sourceFitImage
    }

    /// Punch / recover / blend for the focused ladder (HL or SH).
    private var focusedLadderImages: (NSImage?, NSImage?, NSImage?) {
        switch ladderFocus {
        case .highlights where hlLadderActive:
            return (hlPunchImage, hlRecoverImage, hlBlendImage)
        case .shadows where shLadderActive:
            return (shPunchImage, shRecoverImage, shBlendImage)
        case _ where shLadderActive:
            return (shPunchImage, shRecoverImage, shBlendImage)
        case _ where hlLadderActive:
            return (hlPunchImage, hlRecoverImage, hlBlendImage)
        default:
            return (nil, nil, nil)
        }
    }

    private func zoomLayer(size: CGSize) -> some View {
        let image: NSImage? = {
            if (hlLadderActive || shLadderActive), hsDebugStage != .final {
                return displayedFitImage
            }
            return developedFull ?? developedFit ?? sourceFitImage
        }()
        return ZStack {
            Color.black
            if let image {
                let pixels = PreviewService.pixelSize(image)
                let layout: (width: Int, height: Int) = {
                    if hsDebugStage == .final, developedFull != nil { return pixels }
                    if hsDebugStage == .final,
                       let photo = session.currentPhoto,
                       let native = previews.fullPixelSize(for: photo) {
                        return zoomLayoutSize(bitmap: pixels, native: native)
                    }
                    return pixels
                }()
                let backing = NSScreen.main?.backingScaleFactor ?? 2
                let scale = 1.0 / max(backing, 1)
                let display = CGSize(
                    width: CGFloat(layout.width) * scale,
                    height: CGFloat(layout.height) * scale
                )
                let fx = min(1, max(0, zoomMouseFraction.x))
                let fy = min(1, max(0, zoomMouseFraction.y))
                let originX = fx * (size.width - display.width)
                let originY = fy * (size.height - display.height)

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: display.width, height: display.height)
                    .position(
                        x: originX + display.width / 2,
                        y: originY + display.height / 2
                    )
                    .id("grade-zoom-\(session.currentPhoto?.id ?? "")-\(hsDebugStage.rawValue)")
                    .transaction { $0.animation = nil }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
    }

    private var inspectorCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.currentPhoto?.fileName ?? "Grade")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)

            Picker("", selection: Binding(
                get: { session.developColorMode },
                set: { session.developColorMode = $0 }
            )) {
                Text("LAB").tag(DevelopColorMode.lab)
                Text("RGB").tag(DevelopColorMode.rgb)
            }
            .pickerStyle(.segmented)

            Text(session.developColorMode.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))

            slider(
                "Base",
                value: Binding(
                    get: { session.developBaseBoost * 100 },
                    set: { v in session.developBaseBoost = v / 100 }
                ),
                range: 0...100,
                format: "%.0f"
            )

            slider(
                "Temperature",
                value: Binding(
                    get: {
                        let stored = session.gradeRecipe.temperature
                        return stored > 0 ? stored : session.asShotKelvin
                    },
                    set: { v in
                        let snapped = abs(v - session.asShotKelvin) < 25 ? 0 : v.rounded()
                        session.updateGradeRecipe { $0.temperature = snapped }
                    }
                ),
                range: WhiteBalanceLimits.kelvinRange,
                format: "%.0f K"
            )

            slider(
                "Tint",
                value: Binding(
                    get: { session.gradeRecipe.tint },
                    set: { v in session.updateGradeRecipe { $0.tint = v.rounded() } }
                ),
                range: WhiteBalanceLimits.tintRange,
                format: "%+.0f"
            )

            slider("Exposure", value: Binding(
                get: { session.gradeRecipe.exposure },
                set: { v in session.updateGradeRecipe { $0.exposure = v } }
            ), range: ExposureLimits.evRange)

            slider(
                "Contrast",
                value: Binding(
                    get: { session.gradeRecipe.contrast * 100 },
                    set: { v in session.updateGradeRecipe { $0.contrast = v / 100 } }
                ),
                range: -100...100,
                format: "%+.0f"
            )

            slider("Highlights", value: Binding(
                get: { session.gradeRecipe.highlights },
                set: { v in
                    ladderFocus = .highlights
                    session.updateGradeRecipe { $0.highlights = v }
                }
            ), range: -1...1)

            if hlLadderActive {
                ladderControls(kind: .highlights)
            }

            slider("Shadows", value: Binding(
                get: { session.gradeRecipe.shadows },
                set: { v in
                    ladderFocus = .shadows
                    session.updateGradeRecipe { $0.shadows = v }
                }
            ), range: -1...1)

            if shLadderActive {
                ladderControls(kind: .shadows)
            }

            Button("Reset") {
                // Drop CIRAW caches so identity re-demosaics, but keep the last
                // developed bitmap on screen — clearing it flashes black when Base
                // reset also wipes PreviewService.
                cachedFitCI = nil
                cachedFitKey = ""
                cachedFullCI = nil
                cachedFullKey = ""
                session.resetGradeDefaults()
                enqueueRender(wantFull: session.isPixelZoom)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: inspectorWidth)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.12).opacity(session.isPixelZoom ? 0.92 : 1))
        )
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String = "%+.2f"
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private var sourceFitImage: NSImage? {
        guard let photo = session.currentPhoto else { return nil }
        return previews.displayImage(for: photo)
            ?? previews.viewportImages[photo.id]
            ?? previews.image(for: photo)
    }

    private var fitCacheKey: String {
        let id = session.currentPhoto?.id ?? ""
        let raw = effectiveRAWDevelopKey
        return "\(id)|raw\(raw)|v\(previews.viewportRevision)|f\(previews.fullResolutionRevision)"
    }

    private var fullCacheKey: String {
        let id = session.currentPhoto?.id ?? ""
        let raw = effectiveRAWDevelopKey
        return "\(id)|full|raw\(raw)|\(previews.fullResolutionRevision)"
    }

    private var effectiveRAWDevelopKey: String {
        let k = session.gradeRecipe.temperature > 0
            ? session.gradeRecipe.temperature
            : session.asShotKelvin
        let t = abs(session.gradeRecipe.tint) > 0.5
            ? session.gradeRecipe.tint
            : session.asShotTint
        let ev = session.gradeRecipe.exposure
        let base = session.developBaseBoost
        let recover = session.gradeRecipe.cirawBoostAmount(baseBoost: base)
        let h = session.gradeRecipe.highlights
        let s = session.gradeRecipe.shadows
        return "\(Int(k.rounded()))_\(Int(t.rounded()))_\(String(format: "%.2f", ev))_p\(String(format: "%.3f", base))_r\(String(format: "%.3f", recover))_h\(String(format: "%.2f", h))_s\(String(format: "%.2f", s))"
    }

    private func resolvedWhiteBalance(
        recipe: EditRecipe,
        asShotKelvin: Double,
        asShotTint: Double
    ) -> RAWWhiteBalance {
        let kelvin = recipe.temperature > 0 ? recipe.temperature : asShotKelvin
        let tint = abs(recipe.tint) > 0.5 ? recipe.tint : asShotTint
        return RAWWhiteBalance(kelvin: kelvin, tint: tint)
    }

    private func usesCustomWhiteBalance(
        _ wb: RAWWhiteBalance,
        asShotKelvin: Double,
        asShotTint: Double
    ) -> Bool {
        abs(wb.kelvin - asShotKelvin) > 0.5 || abs(wb.tint - asShotTint) > 0.5
    }

    /// Coalesce: at most one develop in flight; always apply the latest recipe when free.
    private func enqueueRender(wantFull: Bool) {
        if wantFull { pendingFull = true }
        guard !isRendering else {
            pendingRender = true
            return
        }
        startRender()
    }

    private func scheduleFullUpgrade() {
        fullUpgradeTask?.cancel()
        fullUpgradeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            enqueueRender(wantFull: true)
        }
    }

    private func startRender() {
        guard let photo = session.currentPhoto else { return }
        let recipe = session.gradeRecipe
        let mode = session.developColorMode
        let asShotKelvin = session.asShotKelvin
        let asShotTint = session.asShotTint
        let wb = resolvedWhiteBalance(
            recipe: recipe,
            asShotKelvin: asShotKelvin,
            asShotTint: asShotTint
        )
        let customWB = usesCustomWhiteBalance(wb, asShotKelvin: asShotKelvin, asShotTint: asShotTint)
        let customEV = abs(recipe.exposure) > 0.0001
        let baseBoost = session.developBaseBoost
        let cirawBoost = recipe.cirawBoostAmount(baseBoost: baseBoost)
        // Negative Highlights / positive Shadows re-demosaic — detail lives in RAW.
        let needsHighlightRecover = recipe.highlights < -0.0001
        let needsShadowRecover = recipe.shadows > 0.0001
        let needsCIRAW = customWB || customEV || needsHighlightRecover || needsShadowRecover
            || abs(baseBoost - DevelopPrefs.defaultBaseBoost) > 0.0005
        let wantFull = pendingFull && session.isPixelZoom
        pendingFull = false

        let fitSource = sourceFitImage
        let fullSource = wantFull ? (previews.fullImage(for: photo) ?? fitSource) : nil
        let fitKey = fitCacheKey
        let fullKey = fullCacheKey
        let scrubCap = scrubMaxPixels
        let photoURL = photo.url

        // +Shadows always re-demosaic at scrub size so SH ladder bitmaps stay fresh.
        var fitCI = (cachedFitKey == fitKey && !needsShadowRecover) ? cachedFitCI : nil
        var fullCI = (cachedFullKey == fullKey) ? cachedFullCI : nil
        let fitCacheHit = fitCI != nil

        isRendering = true
        let generation = renderGeneration &+ 1
        renderGeneration = generation

        Task.detached(priority: .userInitiated) {
            // Camera Raw–style: bake WB + exposure + Base/HL/SH into CIRAW.
            // Residual post tone runs after; +Shadows zeroed only when SH blend ran.
            var scrubRecipe: EditRecipe
            var fullRecipe: EditRecipe
            var outHLPunch: NSImage?
            var outHLRecover: NSImage?
            var outHLBlend: NSImage?
            var outSHPunch: NSImage?
            var outSHRecover: NSImage?
            var outSHBlend: NSImage?
            var hlBlendOK = false
            var shadowBlendOK = false

            let missingFitSource = fitCI == nil && fitSource == nil
            let missingFullSource = wantFull && fullCI == nil && fullSource == nil
            let runCIRAW = needsCIRAW || missingFitSource || missingFullSource
            let shadowAmount = max(0, recipe.shadows)
            let shadowOpen = recipe.cirawShadowOpenAmount()

            func bakeRecipe(shadowOK: Bool) -> EditRecipe {
                var bake = recipe.afterCIRAWBake
                if shadowOK, bake.shadows > 0 {
                    bake.shadows = 0
                }
                return bake
            }

            if runCIRAW {
                let cirawWB: RAWWhiteBalance? = customWB ? wb : nil
                let cirawEV: Double? = customEV ? recipe.exposure : nil
                let recoverAmount = max(0, -recipe.highlights)

                func demosaicDual(maxPixelSize: CGFloat?, captureLadder: Bool) -> CIImage? {
                    let punch = RAWRender.demosaicCIImage(
                        url: photoURL,
                        maxPixelSize: maxPixelSize,
                        whiteBalance: cirawWB,
                        exposureEV: cirawEV,
                        boostAmount: baseBoost
                    )
                    guard let punch else { return nil }

                    var img = punch

                    if needsHighlightRecover,
                       let hl = RAWRender.demosaicCIImage(
                        url: photoURL,
                        maxPixelSize: maxPixelSize,
                        whiteBalance: cirawWB,
                        exposureEV: cirawEV,
                        boostAmount: cirawBoost
                       ) {
                        if recoverAmount >= 0.99, !needsShadowRecover {
                            img = hl
                        } else {
                            img = DevelopPipeline.blendHighlightRecover(
                                punch: img,
                                recover: hl,
                                amount: recoverAmount
                            )
                        }
                        hlBlendOK = true
                        if captureLadder {
                            outHLPunch = DevelopPipeline.bitmap(from: punch)
                            outHLRecover = DevelopPipeline.bitmap(from: hl)
                            outHLBlend = DevelopPipeline.bitmap(from: img)
                        }
                    }

                    if needsShadowRecover {
                        if let sh = RAWRender.demosaicCIImage(
                            url: photoURL,
                            maxPixelSize: maxPixelSize,
                            whiteBalance: cirawWB,
                            exposureEV: cirawEV,
                            boostAmount: baseBoost,
                            shadowOpen: shadowOpen
                        ) {
                            let beforeShadow = img
                            img = DevelopPipeline.blendShadowRecover(
                                punch: beforeShadow,
                                recover: sh,
                                amount: shadowAmount
                            )
                            shadowBlendOK = true
                            if captureLadder {
                                outSHPunch = DevelopPipeline.bitmap(from: beforeShadow)
                                outSHRecover = DevelopPipeline.bitmap(from: sh)
                                outSHBlend = DevelopPipeline.bitmap(from: img)
                            }
                        } else {
                            print("HS ladder: shadowOpen demosaic FAILED sOpen=\(String(format: "%.2f", shadowOpen))")
                        }
                    }

                    return img
                }

                if fitCI == nil {
                    if needsHighlightRecover || needsShadowRecover,
                       let blended = demosaicDual(maxPixelSize: scrubCap, captureLadder: true) {
                        fitCI = blended
                        scrubRecipe = bakeRecipe(shadowOK: shadowBlendOK)
                    } else if let demosaiced = RAWRender.demosaicCIImage(
                        url: photoURL,
                        maxPixelSize: scrubCap,
                        whiteBalance: cirawWB,
                        exposureEV: cirawEV,
                        boostAmount: baseBoost
                    ) {
                        fitCI = demosaiced
                        scrubRecipe = bakeRecipe(shadowOK: false)
                    } else if let fitSource {
                        fitCI = DevelopPipeline.makeCIImage(from: fitSource)
                        scrubRecipe = recipe
                    } else {
                        scrubRecipe = bakeRecipe(shadowOK: false)
                    }
                } else {
                    // Cache hit — SH was baked into fitCI when key matched.
                    scrubRecipe = bakeRecipe(shadowOK: needsShadowRecover)
                }

                print(
                    "HS ladder: h=\(String(format: "%.2f", recoverAmount)) "
                        + "s=\(String(format: "%.2f", shadowAmount)) "
                        + "sOpen=\(String(format: "%.2f", shadowOpen)) "
                        + "shBlend=\(shadowBlendOK) hlBlend=\(hlBlendOK) "
                        + "punchBoost=\(String(format: "%.3f", baseBoost)) "
                        + "hlBoost=\(String(format: "%.3f", cirawBoost)) "
                        + "cacheHit=\(fitCacheHit)"
                )

                if wantFull {
                    if fullCI == nil {
                        let prevShadowOK = shadowBlendOK
                        let prevHLOK = hlBlendOK
                        shadowBlendOK = false
                        hlBlendOK = false
                        if needsHighlightRecover || needsShadowRecover,
                           let blended = demosaicDual(maxPixelSize: nil, captureLadder: false) {
                            fullCI = blended
                            fullRecipe = bakeRecipe(shadowOK: shadowBlendOK)
                        } else if let demosaiced = RAWRender.demosaicCIImage(
                            url: photoURL,
                            maxPixelSize: nil,
                            whiteBalance: cirawWB,
                            exposureEV: cirawEV,
                            boostAmount: baseBoost
                        ) {
                            fullCI = demosaiced
                            fullRecipe = bakeRecipe(shadowOK: false)
                        } else if let fullSource {
                            fullCI = DevelopPipeline.makeCIImage(from: fullSource)
                            fullRecipe = recipe
                        } else {
                            fullRecipe = bakeRecipe(shadowOK: false)
                        }
                        if outSHPunch != nil { shadowBlendOK = true } else { shadowBlendOK = prevShadowOK }
                        if outHLPunch != nil { hlBlendOK = true } else { hlBlendOK = prevHLOK }
                    } else {
                        fullRecipe = bakeRecipe(shadowOK: needsShadowRecover)
                    }
                } else {
                    fullRecipe = scrubRecipe
                }
            } else {
                scrubRecipe = recipe
                fullRecipe = recipe
                if fitCI == nil, let fitSource {
                    fitCI = DevelopPipeline.makeCIImage(from: fitSource)
                }
                if wantFull, fullCI == nil, let fullSource {
                    fullCI = DevelopPipeline.makeCIImage(from: fullSource)
                }
                print(
                    "HS ladder: h=\(String(format: "%.2f", max(0, -recipe.highlights))) "
                        + "s=\(String(format: "%.2f", shadowAmount)) "
                        + "shBlend=false "
                        + "punchBoost=\(String(format: "%.3f", baseBoost)) "
                        + "hlBoost=\(String(format: "%.3f", cirawBoost)) "
                        + "cacheHit=\(fitCacheHit) runCIRAW=false"
                )
            }

            let scrubOut: NSImage?
            if let fitCI {
                scrubOut = DevelopPipeline.render(
                    ciImage: fitCI,
                    recipe: scrubRecipe,
                    colorMode: mode,
                    asShotKelvin: asShotKelvin,
                    maxPixelSize: runCIRAW ? nil : scrubCap
                )
            } else {
                scrubOut = nil
            }

            let fullOut: NSImage?
            if wantFull, let fullCI {
                fullOut = DevelopPipeline.render(
                    ciImage: fullCI,
                    recipe: fullRecipe,
                    colorMode: mode,
                    asShotKelvin: asShotKelvin,
                    maxPixelSize: nil
                )
            } else {
                fullOut = nil
            }

            await MainActor.run {
                if let fitCI {
                    cachedFitCI = fitCI
                    cachedFitKey = fitKey
                }
                if wantFull, let fullCI {
                    cachedFullCI = fullCI
                    cachedFullKey = fullKey
                }

                if generation == renderGeneration {
                    if let scrubOut {
                        developedFit = scrubOut
                    }
                    if let fullOut {
                        developedFull = fullOut
                    } else if !wantFull {
                        developedFull = nil
                    }

                    if hlBlendOK {
                        if let outHLPunch { hlPunchImage = outHLPunch }
                        if let outHLRecover { hlRecoverImage = outHLRecover }
                        if let outHLBlend { hlBlendImage = outHLBlend }
                        hlLadderActive = hlPunchImage != nil && hlRecoverImage != nil && hlBlendImage != nil
                    } else if !needsHighlightRecover {
                        clearHLLadder()
                    }

                    if shadowBlendOK {
                        if let outSHPunch { shPunchImage = outSHPunch }
                        if let outSHRecover { shRecoverImage = outSHRecover }
                        if let outSHBlend { shBlendImage = outSHBlend }
                        // Activate if we have punch+recover at minimum (blend may match final).
                        shLadderActive = shPunchImage != nil && shRecoverImage != nil
                        if shLadderActive, shBlendImage == nil {
                            shBlendImage = shRecoverImage
                        }
                        if shLadderActive {
                            ladderFocus = .shadows
                        }
                    } else if !needsShadowRecover {
                        clearSHLadder()
                    }
                }

                isRendering = false
                let settingsMoved = session.gradeRecipe != recipe
                    || session.developColorMode != mode
                    || abs(session.developBaseBoost - baseBoost) > 0.0001
                if settingsMoved || pendingFull || pendingRender {
                    pendingRender = false
                    startRender()
                }
            }
        }
    }

    @ViewBuilder
    private func ladderControls(kind: HSLadderKind) -> some View {
        let focused = ladderFocus == kind
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(kind.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                if hlLadderActive && shLadderActive {
                    Button(focused ? "viewing" : "view") {
                        ladderFocus = kind
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(focused ? Color.cyan.opacity(0.85) : Color.white.opacity(0.4))
                }
            }
            Picker("", selection: $hsDebugStage) {
                ForEach(HSDebugStage.allCases) { stage in
                    Text(stage.label).tag(stage)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(!focused && hlLadderActive && shLadderActive)
            Text(hsDebugStage.hint(for: kind))
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
            Text("Keys 1–4 flip · D dumps Desktop/\(kind.dumpFolder)")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
            if let ladderDumpStatus, focused {
                Text(ladderDumpStatus)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.cyan.opacity(0.8))
            }
        }
    }

    private func clearHLLadder() {
        hlLadderActive = false
        hlPunchImage = nil
        hlRecoverImage = nil
        hlBlendImage = nil
        if !shLadderActive {
            hsDebugStage = .final
            ladderDumpStatus = nil
        }
    }

    private func clearSHLadder() {
        shLadderActive = false
        shPunchImage = nil
        shRecoverImage = nil
        shBlendImage = nil
        if !hlLadderActive {
            hsDebugStage = .final
            ladderDumpStatus = nil
        }
    }

    private func dumpHSDebugStages() {
        let kind: HSLadderKind = {
            if ladderFocus == .shadows, shLadderActive { return .shadows }
            if hlLadderActive { return .highlights }
            return .shadows
        }()
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/\(kind.dumpFolder)", isDirectory: true)
        let punch: NSImage?
        let recover: NSImage?
        let blend: NSImage?
        switch kind {
        case .highlights:
            punch = hlPunchImage; recover = hlRecoverImage; blend = hlBlendImage
        case .shadows:
            punch = shPunchImage; recover = shRecoverImage; blend = shBlendImage
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stem = session.currentPhoto?.fileName
                .replacingOccurrences(of: "/", with: "_")
                ?? "grade"
            let pairs: [(String, NSImage?)] = [
                ("\(stem)-punch.png", punch),
                ("\(stem)-recover.png", recover),
                ("\(stem)-blend.png", blend),
                ("\(stem)-final.png", developedFit)
            ]
            var written = 0
            for (name, image) in pairs {
                guard let image else { continue }
                try DevelopPipeline.writePNG(image, to: dir.appendingPathComponent(name))
                written += 1
            }
            ladderDumpStatus = written > 0
                ? "Dumped \(written) PNGs → Desktop/\(kind.dumpFolder)"
                : "Nothing to dump — wait for render"
            print("HS ladder dump: \(ladderDumpStatus ?? "")")
        } catch {
            ladderDumpStatus = "Dump failed: \(error.localizedDescription)"
            print("HS ladder dump failed: \(error)")
        }
    }

    private func zoomLayoutSize(
        bitmap: (width: Int, height: Int),
        native: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        let bitmapLong = max(bitmap.width, bitmap.height)
        guard bitmapLong > 0 else { return bitmap }
        let targetLong = max(native.width, native.height)
        let s = CGFloat(targetLong) / CGFloat(bitmapLong)
        return (
            max(1, Int((CGFloat(bitmap.width) * s).rounded())),
            max(1, Int((CGFloat(bitmap.height) * s).rounded()))
        )
    }
}
