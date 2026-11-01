import AppKit
import CoreImage
import Foundation

/// Applies an `EditRecipe` on top of a demosaiced bitmap.
/// Order: WB (RGB) → exposure → contrast → highlights/shadows (LAB-style or RGB) → Display P3.
/// Same CIContext / color space contract as `RAWRender`.
enum DevelopPipeline {
    nonisolated private static let context = RAWRender.ciContext

    /// Screen / export render. `maxPixelSize` nil keeps source resolution.
    nonisolated static func render(
        source: NSImage,
        recipe: EditRecipe,
        colorMode: DevelopColorMode,
        asShotKelvin: Double = WhiteBalanceLimits.defaultAsShotKelvin,
        maxPixelSize: CGFloat? = nil
    ) -> NSImage? {
        guard let ci = makeCIImage(from: source) else { return nil }
        return render(
            ciImage: ci,
            recipe: recipe,
            colorMode: colorMode,
            asShotKelvin: asShotKelvin,
            maxPixelSize: maxPixelSize
        )
            ?? (recipe.isIdentity ? source : nil)
    }

    /// Prefer this when the base bitmap is already a `CIImage` (avoids NSImage→TIFF each scrub).
    nonisolated static func render(
        ciImage source: CIImage,
        recipe: EditRecipe,
        colorMode: DevelopColorMode,
        asShotKelvin: Double = WhiteBalanceLimits.defaultAsShotKelvin,
        maxPixelSize: CGFloat? = nil
    ) -> NSImage? {
        var ciImage = source

        if let maxPixelSize {
            let longEdge = max(ciImage.extent.width, ciImage.extent.height)
            if longEdge > maxPixelSize {
                let scale = maxPixelSize / longEdge
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        if !recipe.isIdentity {
            ciImage = apply(recipe, colorMode: colorMode, asShotKelvin: asShotKelvin, to: ciImage)
        }
        return nsImage(from: ciImage)
    }

    /// Cheap NSImage → CIImage (CGImage first; TIFF only as fallback).
    nonisolated static func makeCIImage(from nsImage: NSImage) -> CIImage? {
        var rect = CGRect(origin: .zero, size: nsImage.size)
        if let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return CIImage(cgImage: cg)
        }
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage
        else { return nil }
        return CIImage(cgImage: cg)
    }

    nonisolated static func apply(
        _ recipe: EditRecipe,
        colorMode: DevelopColorMode,
        asShotKelvin: Double = WhiteBalanceLimits.defaultAsShotKelvin,
        to image: CIImage
    ) -> CIImage {
        var img = applyWhiteBalance(recipe, asShotKelvin: asShotKelvin, to: image)
        switch colorMode {
        case .lab:
            img = applyToneLAB(recipe, to: img)
        case .rgb:
            img = applyToneRGB(recipe, to: img)
        }
        return img
    }

    /// ACR-style Highlights: keep punch midtones, swap in low-boost RAW in the shoulder.
    /// Uses explicit multiply+add (not CIBlendWithMask) — mask blends were a silent no-op
    /// for CIRAW float images in practice.
    nonisolated static func blendHighlightRecover(
        punch: CIImage,
        recover: CIImage,
        amount: Double
    ) -> CIImage {
        blendRecoverLayer(punch: punch, recover: recover, amount: amount, shadowToe: false)
    }

    /// ACR-style Shadows: keep punch mids/highlights, swap in toe-opened layer.
    nonisolated static func blendShadowRecover(
        punch: CIImage,
        recover: CIImage,
        amount: Double
    ) -> CIImage {
        blendRecoverLayer(punch: punch, recover: recover, amount: amount, shadowToe: true)
    }

    /// Weak non-RAW / ladder helper: luma toe remap on an existing bitmap.
    /// RAW Grade +Shadows use CIRAW `shadowOpen` demosaic instead.
    nonisolated static func shadowOpenLayer(_ image: CIImage, amount: Double) -> CIImage {
        let a = min(1, max(0, amount))
        guard a > 0.0001 else { return image }
        let data = shadowOpenCubeData(amount: a)
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": hsCubeSize,
            "inputCubeData": data
        ])
    }

    nonisolated private static func shadowOpenCubeData(amount: Double) -> Data {
        let n = hsCubeSize
        let denom = Double(max(n - 1, 1))
        let a = min(1, max(0, amount))
        var bytes = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n {
            let b = Double(bi) / denom
            for gi in 0..<n {
                let g = Double(gi) / denom
                for ri in 0..<n {
                    let r = Double(ri) / denom
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let y2 = shadowOpenTransfer(y, amount: a)
                    let rr = min(1, max(0, r - y + y2))
                    let gg = min(1, max(0, g - y + y2))
                    let bb = min(1, max(0, b - y + y2))
                    let i = ((bi * n + gi) * n + ri) * 4
                    bytes[i + 0] = Float(rr)
                    bytes[i + 1] = Float(gg)
                    bytes[i + 2] = Float(bb)
                    bytes[i + 3] = 1
                }
            }
        }
        return bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Open the toe like ACR +Shadows: doorway/canopy readable, mids/highlights untouched.
    /// No black-floor add (that milked the frame into flat gray).
    nonisolated private static func shadowOpenTransfer(_ x: Double, amount: Double) -> Double {
        func smoothstep(_ edge0: Double, _ edge1: Double, _ v: Double) -> Double {
            let t = max(0, min(1, (v - edge0) / max(1e-6, edge1 - edge0)))
            return t * t * (3 - 2 * t)
        }
        let x0 = max(0, min(1, x))
        let a = min(1, max(0, amount))
        guard a > 1e-4 else { return x0 }
        // ACR Shadows zone — stop before midtones so walls/sky don’t wash.
        let w = pow(1.0 - smoothstep(0.02, 0.40, x0), 1.0)
        guard w > 1e-4 else { return x0 }
        // Power open with a small toe bias so near-black moves, without raising the
        // whole shadow mass to a single gray (ACR keeps bark/doorway structure).
        let g = 1.0 / (1.0 + a * 2.1)
        let biased = x0 + a * 0.045 * w
        let lifted = pow(max(biased, 1e-4), g)
        // Soften: don’t take the full power remap (keeps local contrast).
        let opened = x0 + (lifted - x0) * (0.72 + 0.28 * a) * w
        return max(0, min(1, opened))
    }

    nonisolated private static func blendRecoverLayer(
        punch: CIImage,
        recover: CIImage,
        amount: Double,
        shadowToe: Bool
    ) -> CIImage {
        let a = min(1, max(0, amount))
        guard a > 0.0001 else { return punch }

        let punchImg = punch.clampedToExtent()
        // Do not brighten recover here — that re-clipped the shoulder and made −H a no-op.
        // Ladder: stage 2 (raw recover) already has the detail users want.
        var recoverImg = recover.clampedToExtent()
        let pExtent = punch.extent
        let rExtent = recoverImg.extent
        if abs(pExtent.width - rExtent.width) > 0.5
            || abs(pExtent.height - rExtent.height) > 0.5 {
            let sx = pExtent.width / max(rExtent.width, 1)
            let sy = pExtent.height / max(rExtent.height, 1)
            recoverImg = recoverImg.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .clampedToExtent()
        }

        let luma = punchImg.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let mask = shadowToe
            ? shadowRecoverMask(fromLuma: luma, amount: a)
            : recoverMask(fromLuma: luma, amount: a)
        // 1 − mask
        let invMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
        ])
        // punch*(1−m) + recover*m
        let punchPart = punchImg.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: invMask
        ])
        let recoverPart = recoverImg.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: mask
        ])
        let blended = punchPart.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: recoverPart
        ])
        return blended.cropped(to: pExtent)
    }

    /// Optional mid lift for ladder preview only — not used in the blend path.
    nonisolated static func prepareRecoverLayer(_ recover: CIImage, amount: Double) -> CIImage {
        let a = min(1, max(0, amount))
        guard a > 0.0001 else { return recover }
        let fill = a * 0.55
        let data = recoverBrightenCubeData(amount: fill)
        return recover.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": hsCubeSize,
            "inputCubeData": data
        ])
    }

    nonisolated private static func recoverBrightenCubeData(amount: Double) -> Data {
        let n = hsCubeSize
        let denom = Double(max(n - 1, 1))
        let a = min(1, max(0, amount))
        var bytes = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n {
            let b = Double(bi) / denom
            for gi in 0..<n {
                let g = Double(gi) / denom
                for ri in 0..<n {
                    let r = Double(ri) / denom
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let y2 = recoverBrightenTransfer(y, amount: a)
                    let rr = min(1, max(0, r - y + y2))
                    let gg = min(1, max(0, g - y + y2))
                    let bb = min(1, max(0, b - y + y2))
                    let i = ((bi * n + gi) * n + ri) * 4
                    bytes[i + 0] = Float(rr)
                    bytes[i + 1] = Float(gg)
                    bytes[i + 2] = Float(bb)
                    bytes[i + 3] = 1
                }
            }
        }
        return bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated private static func recoverBrightenTransfer(_ x: Double, amount: Double) -> Double {
        func smoothstep(_ edge0: Double, _ edge1: Double, _ v: Double) -> Double {
            let t = max(0, min(1, (v - edge0) / max(1e-6, edge1 - edge0)))
            return t * t * (3 - 2 * t)
        }
        let x0 = max(0, min(1, x))
        let lo = smoothstep(0.05, 0.18, x0)
        let hi = 1.0 - smoothstep(0.42, 0.62, x0)
        return min(1, x0 + amount * 0.28 * lo * hi)
    }

    /// Grayscale weight map: 0 = keep punch, 1 = take recover.
    nonisolated private static func recoverMask(fromLuma luma: CIImage, amount: Double) -> CIImage {
        let data = recoverMaskCubeData(amount: amount)
        return luma.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": hsCubeSize,
            "inputCubeData": data
        ])
    }

    nonisolated private static func shadowRecoverMask(fromLuma luma: CIImage, amount: Double) -> CIImage {
        let data = shadowRecoverMaskCubeData(amount: amount)
        return luma.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": hsCubeSize,
            "inputCubeData": data
        ])
    }

    nonisolated private static func recoverMaskCubeData(amount: Double) -> Data {
        let n = hsCubeSize
        let denom = Double(max(n - 1, 1))
        let a = min(1, max(0, amount))
        var bytes = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n {
            let b = Double(bi) / denom
            for gi in 0..<n {
                let g = Double(gi) / denom
                for ri in 0..<n {
                    let r = Double(ri) / denom
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    // Broad shoulder gate so hat/lamp clearly take recover.
                    let t = max(0, min(1, (y - 0.40) / 0.50))
                    let w = t * t * (3 - 2 * t)
                    let m = Float(w * a)
                    let i = ((bi * n + gi) * n + ri) * 4
                    bytes[i + 0] = m
                    bytes[i + 1] = m
                    bytes[i + 2] = m
                    bytes[i + 3] = 1
                }
            }
        }
        return bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Toe gate: deep shadows only — fade before midtones so punch keeps walls/sky.
    nonisolated private static func shadowRecoverMaskCubeData(amount: Double) -> Data {
        let n = hsCubeSize
        let denom = Double(max(n - 1, 1))
        let a = min(1, max(0, amount))
        var bytes = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n {
            let b = Double(bi) / denom
            for gi in 0..<n {
                let g = Double(gi) / denom
                for ri in 0..<n {
                    let r = Double(ri) / denom
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    // Tight ACR-ish Shadows zone (~0…0.32).
                    let t = max(0, min(1, 1.0 - (y - 0.01) / 0.32))
                    let w = t * t * (3 - 2 * t)
                    let m = Float(w * a)
                    let i = ((bi * n + gi) * n + ri) * 4
                    bytes[i + 0] = m
                    bytes[i + 1] = m
                    bytes[i + 2] = m
                    bytes[i + 3] = 1
                }
            }
        }
        return bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - WB (Kelvin + tint via CITemperatureAndTint)

    /// Maps user Kelvin/tint → as-shot reference via CITemperatureAndTint.
    /// `recipe.temperature == 0` means as-shot.
    ///
    /// Neutral = user’s assumed illuminant, Target = as-shot. Lower Kelvin on Neutral
    /// cools the image (Camera Raw direction). Swapping these made left-drag go warmer first.
    nonisolated private static func applyWhiteBalance(
        _ recipe: EditRecipe,
        asShotKelvin: Double,
        to image: CIImage
    ) -> CIImage {
        let srcK = min(
            WhiteBalanceLimits.kelvinRange.upperBound,
            max(WhiteBalanceLimits.kelvinRange.lowerBound, asShotKelvin)
        )
        let destK = recipe.temperature > 0
            ? min(
                WhiteBalanceLimits.kelvinRange.upperBound,
                max(WhiteBalanceLimits.kelvinRange.lowerBound, recipe.temperature)
            )
            : srcK
        let destTint = min(
            WhiteBalanceLimits.tintRange.upperBound,
            max(WhiteBalanceLimits.tintRange.lowerBound, recipe.tint)
        )

        guard abs(destK - srcK) > 0.5 || abs(destTint) > 0.5 else { return image }

        return image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: CGFloat(destK), y: 0),
            "inputTargetNeutral": CIVector(x: CGFloat(srcK), y: CGFloat(destTint))
        ])
    }

    // MARK: - Exposure (fallback when not baked into CIRAW)

    /// Negative EV: linear gain. Positive EV: gain with a soft highlight shoulder so
    /// midtones lift without slamming display-referred highlights to clip (ACR-like).
    /// Prefer CIRAW `exposure` on RAW — this path is for JPEG / demosaic fallback.
    nonisolated private static func applyExposure(_ ev: Double, to image: CIImage) -> CIImage {
        let clamped = min(ExposureLimits.evRange.upperBound, max(ExposureLimits.evRange.lowerBound, ev))
        guard abs(clamped) > 0.0001 else { return image }
        if clamped <= 0 {
            return image.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: clamped
            ])
        }
        let data = exposureProtectCubeData(ev: clamped)
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": hsCubeSize,
            "inputCubeData": data
        ])
    }

    /// Luma-preserving gain with shoulder. `ev` must be > 0.
    nonisolated private static func exposureProtectCubeData(ev: Double) -> Data {
        let n = hsCubeSize
        let denom = Double(max(n - 1, 1))
        let gain = pow(2.0, ev)
        // Stronger positive EV → stronger rolloff above ~mid gray.
        let protect = min(1.35, 0.55 + 0.16 * ev)
        var bytes = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n {
            let b = Double(bi) / denom
            for gi in 0..<n {
                let g = Double(gi) / denom
                for ri in 0..<n {
                    let r = Double(ri) / denom
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let y2 = highlightSafeExposure(y, gain: gain, protect: protect)
                    let scale = y2 / max(y, 0.0001)
                    let rr = min(1, max(0, r * scale))
                    let gg = min(1, max(0, g * scale))
                    let bb = min(1, max(0, b * scale))
                    let i = ((bi * n + gi) * n + ri) * 4
                    // CIColorCube cells are RGBA (B varies fastest in the index layout we use).
                    bytes[i + 0] = Float(rr)
                    bytes[i + 1] = Float(gg)
                    bytes[i + 2] = Float(bb)
                    bytes[i + 3] = 1
                }
            }
        }
        return bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Lift with soft compression above ~0.45 so highlights approach white slowly.
    nonisolated private static func highlightSafeExposure(
        _ x: Double,
        gain: Double,
        protect: Double
    ) -> Double {
        let lifted = x * gain
        let over = max(0.0, lifted - 0.38)
        let compressed = lifted / (1.0 + protect * over * 3.2)
        return max(0.0, min(1.0, compressed))
    }

    // MARK: - RGB tone

    nonisolated private static func applyToneRGB(_ recipe: EditRecipe, to image: CIImage) -> CIImage {
        var img = image
        if abs(recipe.exposure) > 0.0001 {
            img = applyExposure(recipe.exposure, to: img)
        }
        if abs(recipe.contrast) > 0.0001 {
            img = applyContrast(recipe.contrast, to: img)
        }
        return applyLumaToneCurve(recipe, to: img)
    }

    // MARK: - LAB-style tone (luminance only — preserves chromaticity)

    /// Exposure, then contrast + H/S on Rec.709 luminance.
    /// Recombine with additive luma swap (`Y' + (rgb−Y)·chromaKeep`).
    /// Chroma is attenuated on −contrast (ACR −100 is milky, not neon) and
    /// left alone / slightly boosted on +contrast (ACR +100 pops color).
    nonisolated private static func applyToneLAB(_ recipe: EditRecipe, to image: CIImage) -> CIImage {
        var img = image

        if abs(recipe.exposure) > 0.0001 {
            img = applyExposure(recipe.exposure, to: img)
        }

        let needsLumaTone = abs(recipe.contrast) > 0.0001
            || abs(recipe.highlights) > 0.0001
            || abs(recipe.shadows) > 0.0001
            || recipe.midtoneFill > 0.0001
        guard needsLumaTone else { return img }

        // Luminance plane (same value in R/G/B).
        let luma = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])

        var adjustedLuma = luma
        if abs(recipe.contrast) > 0.0001 {
            adjustedLuma = applyContrast(recipe.contrast, to: adjustedLuma)
        }
        adjustedLuma = applyLumaToneCurve(recipe, to: adjustedLuma)

        // chroma = rgb − Y
        let negLuma = luma.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        var chroma = img.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: negLuma
        ])
        let keep = contrastChromaKeep(recipe.contrast)
        if abs(keep - 1.0) > 0.0001 {
            chroma = chroma.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        }
        // out = chroma·keep + Y'
        return chroma.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: adjustedLuma
        ])
    }

    // MARK: - Contrast (ACR-like S-curve)

    /// UI ±100 reaches a strong extreme; mid travel is eased so ±25 isn’t already ACR ±100.
    /// `pow(|c|, 2.1)` → |0.25|≈0.05, |0.50|≈0.23, |1.0|=1.0.
    nonisolated private static func contrastEffectiveAmount(_ amount: Double) -> Double {
        let c = min(1, max(-1, amount))
        let a = abs(c)
        guard a > 0.0001 else { return 0 }
        return (c < 0 ? -1.0 : 1.0) * pow(a, 2.1)
    }

    /// `amount` in −1…+1. Positive: steeper midtone slope with soft shoulders.
    /// Negative: flatten toward mid-gray (ACR −100 ≈ mid needle).
    nonisolated private static func applyContrast(_ amount: Double, to image: CIImage) -> CIImage {
        let data = contrastCubeData(amount: amount)
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": hsCubeSize,
            "inputCubeData": data
        ])
    }

    /// ACR −100 washes color; +100 slightly pops it. Never the reverse.
    nonisolated private static func contrastChromaKeep(_ amount: Double) -> Double {
        let c = contrastEffectiveAmount(amount)
        if c < 0 {
            return max(0.12, 1.0 + c * 0.88) // −1 → ~0.12
        }
        return 1.0 + c * 0.10
    }

    nonisolated private static func contrastCubeData(amount: Double) -> Data {
        let n = hsCubeSize
        let denom = Double(max(n - 1, 1))
        let c = contrastEffectiveAmount(amount)
        let keep = contrastChromaKeep(amount)
        var bytes = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n {
            let b = Double(bi) / denom
            for gi in 0..<n {
                let g = Double(gi) / denom
                for ri in 0..<n {
                    let r = Double(ri) / denom
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let y2 = contrastTransfer(y, amount: c)
                    // Additive luma swap with contrast-linked chroma.
                    let rr = min(1, max(0, y2 + (r - y) * keep))
                    let gg = min(1, max(0, y2 + (g - y) * keep))
                    let bb = min(1, max(0, y2 + (b - y) * keep))
                    let i = ((bi * n + gi) * n + ri) * 4
                    // CIColorCube cells are RGBA (B varies fastest in the index layout we use).
                    bytes[i + 0] = Float(rr)
                    bytes[i + 1] = Float(gg)
                    bytes[i + 2] = Float(bb)
                    bytes[i + 3] = 1
                }
            }
        }
        return bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Operates on *effective* amount (−1…+1 after slider shaping).
    /// Extremes are strong but a touch short of ACR so the last quarter of travel stays useful.
    nonisolated private static func contrastTransfer(_ x: Double, amount: Double) -> Double {
        let c = min(1, max(-1, amount))
        let x0 = min(1 - 1e-6, max(1e-6, x))
        guard abs(c) > 0.0001 else { return max(0, min(1, x)) }

        if c < 0 {
            let flatten = 1.0 + c * 0.85 // −1 → ~15% residual (ACR is tighter; we stay usable)
            return min(1, max(0, 0.5 + (x0 - 0.5) * flatten))
        }

        let pivot = 0.48
        let gs = 1.0 + c * 1.15
        let gh = 1.0 + c * 1.65
        let y: Double
        if x0 < pivot {
            y = pivot * pow(x0 / pivot, gs)
        } else {
            y = 1.0 - (1.0 - pivot) * pow((1.0 - x0) / (1.0 - pivot), gh)
        }
        return min(1, max(0, y))
    }

    /// Single cube for midtone fill + H/S — stacking cubes on 8-bit data posterized.
    nonisolated private static let hsCubeSize = 64

    nonisolated private static func applyLumaToneCurve(_ recipe: EditRecipe, to image: CIImage) -> CIImage {
        let fill = recipe.midtoneFill
        guard abs(recipe.highlights) > 0.0001
            || abs(recipe.shadows) > 0.0001
            || fill > 0.0001
        else { return image }
        let data = hsCubeData(
            highlights: recipe.highlights,
            shadows: recipe.shadows,
            midtoneFill: fill
        )
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": hsCubeSize,
            "inputCubeData": data
        ])
    }

    /// Applies fill then `hsTransfer` to Rec.709 luma, then additive luma swap.
    nonisolated private static func hsCubeData(
        highlights h: Double,
        shadows s: Double,
        midtoneFill fill: Double
    ) -> Data {
        let n = hsCubeSize
        let denom = Double(max(n - 1, 1))
        var bytes = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n {
            let b = Double(bi) / denom
            for gi in 0..<n {
                let g = Double(gi) / denom
                for ri in 0..<n {
                    let r = Double(ri) / denom
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    var y2 = y
                    if fill > 0.0001 {
                        y2 = midtoneFillTransfer(y2, amount: fill)
                    }
                    y2 = hsTransfer(y2, highlights: h, shadows: s)
                    let rr = min(1, max(0, r - y + y2))
                    let gg = min(1, max(0, g - y + y2))
                    let bb = min(1, max(0, b - y + y2))
                    let i = ((bi * n + gi) * n + ri) * 4
                    bytes[i + 0] = Float(rr)
                    bytes[i + 1] = Float(gg)
                    bytes[i + 2] = Float(bb)
                    bytes[i + 3] = 1
                }
            }
        }
        return bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated private static func midtoneFillTransfer(_ x: Double, amount: Double) -> Double {
        func smoothstep(_ edge0: Double, _ edge1: Double, _ v: Double) -> Double {
            let t = max(0, min(1, (v - edge0) / max(1e-6, edge1 - edge0)))
            return t * t * (3 - 2 * t)
        }
        let x0 = max(0, min(1, x))
        let a = min(1, max(0, amount))
        let lo = smoothstep(0.08, 0.28, x0)
        let hi = 1.0 - smoothstep(0.62, 0.88, x0)
        return min(1, x0 + a * 0.28 * lo * hi)
    }

    /// `h`/`s` in −1…+1. ACR Highlights stay on the upper shoulder; Shadows on the toe.
    /// Negative highlights compress the shoulder toward mid — monotonically (no tone inversion).
    nonisolated private static func hsTransfer(_ x: Double, highlights h: Double, shadows s: Double) -> Double {
        func smoothstep(_ edge0: Double, _ edge1: Double, _ v: Double) -> Double {
            let t = max(0, min(1, (v - edge0) / max(1e-6, edge1 - edge0)))
            return t * t * (3 - 2 * t)
        }

        let x0 = max(0, min(1, x))
        var y = x0

        if abs(s) > 0.0001 {
            let w = pow(1.0 - smoothstep(0.0, 0.38, x0), 1.0)
            if s > 0 {
                // Weak non-RAW fallback only — RAW +Shadows use CIRAW dual demosaic
                // and zero residual after bake. Stretching Base-100 punch posterizes.
                y = shadowOpenTransfer(x0, amount: min(1, s) * 0.28)
            } else {
                y -= abs(s) * 0.75 * w
            }
        }

        if abs(h) > 0.0001 {
            if h > 0 {
                // ACR +Highlights: lift the upper shoulder, then filmic approach to white
                // so the shop-light bloom rolls off instead of a hard clipped disk.
                // UI was ~4× hot vs ACR (+0.25 FG ≈ +100 ACR) — compress full travel.
                let amount = h * 0.25
                let w = smoothstep(0.48, 0.92, x0)
                let lifted = x0 * (1.0 + amount * 0.70 * w)
                let knee = 0.72 - amount * 0.06
                if lifted <= knee {
                    y = lifted
                } else {
                    let over = lifted - knee
                    let range = 1.0 - knee
                    // Lower k → reaches white sooner but still asymptotic (smooth roll-off).
                    let k = 0.42 - amount * 0.18
                    y = knee + range * (over / (over + max(0.12, k) * range))
                }
            } else {
                // Soft rolloff above the shoulder — still monotonic / rising so recovered
                // texture stays visible, while pulling the right-edge spike inward like ACR.
                let amount = -h
                let pivot = 0.55
                if x0 <= pivot {
                    y = x0
                } else {
                    let over = x0 - pivot
                    let k = amount * 2.4
                    let rolled = pivot + over / (1.0 + k * over)
                    y = x0 + (rolled - x0) * amount
                }
            }
        }
        return max(0, min(1, y))
    }

    // MARK: - NSImage helpers

    nonisolated private static func nsImage(from ciImage: CIImage) -> NSImage? {
        // CIRAW float graphs can be infinite after clamp — crop to a finite working rect.
        var working = ciImage
        var rect = working.extent.integral
        if rect.isInfinite || rect.isNull || rect.width <= 1 || rect.height <= 1 {
            let extent = working.extent
            guard extent.width.isFinite, extent.height.isFinite,
                  extent.width > 1, extent.height > 1
            else { return nil }
            rect = extent.integral
        }
        working = working.cropped(to: rect)
        guard let cg = context.createCGImage(
            working,
            from: rect,
            format: .RGBA8,
            colorSpace: RAWRender.outputColorSpace
        ) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width, height: cg.height)
        let image = NSImage(size: NSSize(width: cg.width, height: cg.height))
        image.addRepresentation(rep)
        return image
    }

    /// Public bake for HL debug stage dumps / viewer.
    nonisolated static func bitmap(from ciImage: CIImage) -> NSImage? {
        nsImage(from: ciImage)
    }

    /// Write a Display-P3 PNG for diagnostic side-by-side with ACR.
    nonisolated static func writePNG(_ image: NSImage, to url: URL) throws {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}
