import AppKit
import CoreImage
import CoreGraphics
import Foundation

/// Result of a demosaic — bitmap plus exact pixel sizes for 1:1 zoom layout.
struct RAWRenderResult {
    let image: NSImage
    /// Pixel size of `image` (may be display-proxy sized).
    let renderedWidth: Int
    let renderedHeight: Int
    /// Pixel size at scaleFactor 1 (Space zoom / export). Same aspect as rendered.
    let fullWidth: Int
    let fullHeight: Int
}

/// Optional CIRAW white-balance override (Camera Raw–style Kelvin + tint).
struct RAWWhiteBalance: Equatable, Sendable {
    var kelvin: Double
    var tint: Double
}

/// Canonical demosaic / develop preview path for Flipgrade.
///
/// **Contract:** Cover Flow display proxies, Space 1:1 zoom, and (later) export must all
/// call this path with the same CIRAW settings and the same output color space. Resolution
/// may differ (`maxPixelSize`); color science must not.
///
/// Grade may pass `whiteBalance` to override as-shot CIRAW neutrals (still same color space).
/// Temporary camera embedded JPEGs are outside this contract — placeholders only.
enum RAWRender {
    /// Locked display/working space for demosaiced bitmaps (Mac-native wide gamut).
    /// Export can convert to sRGB deliberately at write time; previews stay in this space.
    nonisolated static let outputColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    /// Shared GPU context — float working format so Grade tone cubes don’t posterize
    /// after a CIRAW→8-bit round-trip.
    nonisolated static let ciContext: CIContext = {
        CIContext(options: [
            .workingColorSpace: outputColorSpace,
            .outputColorSpace: outputColorSpace,
            .workingFormat: CIFormat.RGBAh,
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }()

    /// Demosaic with Apple CIRAW (ImageIO fallback). `maxPixelSize` nil = full native size.
    /// `whiteBalance` / `exposureEV` override as-shot CIRAW neutrals / exposure (Grade).
    /// `boostAmount` is CIRAW’s global tone curve (0…1); nil uses full punch `1.0`.
    nonisolated static func demosaic(
        url: URL,
        maxPixelSize: CGFloat?,
        whiteBalance: RAWWhiteBalance? = nil,
        exposureEV: Double? = nil,
        boostAmount: Double? = nil
    ) -> NSImage? {
        demosaicResult(
            url: url,
            maxPixelSize: maxPixelSize,
            whiteBalance: whiteBalance,
            exposureEV: exposureEV,
            boostAmount: boostAmount
        )?.image
    }

    /// Float CIRAW output for Grade develop — skips the 8-bit bake that posterizes
    /// stacked tone cubes after highlight recovery.
    /// `shadowOpen` (0…1) raises CIRAW shadow knobs for the +Shadows recover layer.
    nonisolated static func demosaicCIImage(
        url: URL,
        maxPixelSize: CGFloat?,
        whiteBalance: RAWWhiteBalance? = nil,
        exposureEV: Double? = nil,
        boostAmount: Double? = nil,
        shadowOpen: Double? = nil
    ) -> CIImage? {
        let hasExposure = exposureEV.map { abs($0) > 0.0001 } ?? false
        let hasShadowOpen = shadowOpen.map { $0 > 0.0001 } ?? false
        if let (ci, _) = cirawOutputImage(
            url: url,
            maxPixelSize: maxPixelSize,
            whiteBalance: whiteBalance,
            exposureEV: hasExposure ? exposureEV : nil,
            boostAmount: boostAmount,
            shadowOpen: hasShadowOpen ? shadowOpen : nil
        ) {
            return ci
        }
        // ImageIO can't honor CIRAW neutrals / exposure / shadowOpen.
        guard whiteBalance == nil, !hasExposure, !hasShadowOpen else { return nil }
        guard let io = demosaicImageIO(url: url, maxPixelSize: maxPixelSize) else { return nil }
        return ciImage(from: io.image)
    }

    nonisolated static func demosaicResult(
        url: URL,
        maxPixelSize: CGFloat?,
        whiteBalance: RAWWhiteBalance? = nil,
        exposureEV: Double? = nil,
        boostAmount: Double? = nil,
        shadowOpen: Double? = nil
    ) -> RAWRenderResult? {
        let hasExposure = exposureEV.map { abs($0) > 0.0001 } ?? false
        let hasShadowOpen = shadowOpen.map { $0 > 0.0001 } ?? false
        if let (ciImage, scale) = cirawOutputImage(
            url: url,
            maxPixelSize: maxPixelSize,
            whiteBalance: whiteBalance,
            exposureEV: hasExposure ? exposureEV : nil,
            boostAmount: boostAmount,
            shadowOpen: hasShadowOpen ? shadowOpen : nil
        ) {
            return makeResult(rendering: ciImage, scaleFactor: scale)
        }
        // ImageIO can't honor CIRAW neutrals/exposure/shadowOpen — caller post-processes.
        guard whiteBalance == nil, !hasExposure, !hasShadowOpen else { return nil }
        return demosaicImageIO(url: url, maxPixelSize: maxPixelSize)
    }

    /// As-shot white balance from CIRAW (Kelvin + tint). Nil if unavailable.
    nonisolated static func asShotWhiteBalance(url: URL) -> RAWWhiteBalance? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let kelvin = Double(filter.neutralTemperature)
        let tint = Double(filter.neutralTint)
        guard kelvin >= 1000, kelvin <= 100_000 else { return nil }
        return RAWWhiteBalance(kelvin: kelvin, tint: tint)
    }

    /// CIRAW → CIImage without an 8-bit intermediate. Scale is the CIRAW scaleFactor used.
    nonisolated private static func cirawOutputImage(
        url: URL,
        maxPixelSize: CGFloat?,
        whiteBalance: RAWWhiteBalance?,
        exposureEV: Double?,
        boostAmount: Double?,
        shadowOpen: Double? = nil
    ) -> (CIImage, CGFloat)? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        let longEdge = max(native.width, native.height)
        guard longEdge > 1 else { return nil }

        let scale: CGFloat
        if let maxPixelSize, longEdge > maxPixelSize {
            scale = maxPixelSize / longEdge
            filter.scaleFactor = Float(scale)
        } else {
            scale = 1
            filter.scaleFactor = 1
        }

        filter.isDraftModeEnabled = false

        let boost = boostAmount ?? 1.0
        applyHighlightFriendlyDefaults(to: filter, boostAmount: boost)

        if let whiteBalance {
            let k = min(
                WhiteBalanceLimits.kelvinRange.upperBound,
                max(WhiteBalanceLimits.kelvinRange.lowerBound, whiteBalance.kelvin)
            )
            let t = min(
                WhiteBalanceLimits.tintRange.upperBound,
                max(WhiteBalanceLimits.tintRange.lowerBound, whiteBalance.tint)
            )
            filter.neutralTemperature = Float(k)
            filter.neutralTint = Float(t)
        }

        if let exposureEV, abs(exposureEV) > 0.0001 {
            let ev = min(
                ExposureLimits.evRange.upperBound,
                max(ExposureLimits.evRange.lowerBound, exposureEV)
            )
            filter.exposure = Float(ev)

            if ev > 0 {
                filter.boostShadowAmount = min(1.0, filter.boostShadowAmount + Float(0.12 * ev))
                filter.shadowBias = filter.shadowBias + Float(0.06 * ev)
                if filter.isLocalToneMapSupported {
                    filter.localToneMapAmount = Float(min(0.55, Double(filter.localToneMapAmount) + 0.09 * ev))
                }
                if filter.isContrastSupported {
                    let base = filter.contrastAmount
                    filter.contrastAmount = max(0, base * Float(max(0.55, 1.0 - 0.08 * ev)))
                }
            }
        }

        // +Shadows recover layer: CIRAW shadow knobs only — never post CIExposureAdjust.
        if let shadowOpen {
            applyShadowOpen(to: filter, amount: shadowOpen)
        }

        guard var ciImage = filter.outputImage else { return nil }

        if let exposureEV, exposureEV > 0.0001 {
            let sat = max(0.82, 1.0 - 0.045 * exposureEV)
            ciImage = ciImage.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: sat
            ])
        }

        return (ciImage, scale)
    }

    /// Opens the RAW toe via CIRAW (boostShadowAmount / shadowBias / detail / baseline).
    /// Used for the +Shadows recover demosaic — detail comes from the sensor path.
    /// No post CIExposureAdjust (that milks the frame).
    nonisolated private static func applyShadowOpen(to filter: CIRAWFilter, amount: Double) {
        let a = min(1, max(0, amount))
        guard a > 0.0001 else { return }
        filter.boostShadowAmount = min(
            2.0,
            filter.boostShadowAmount + Float(0.55 + 1.45 * a)
        )
        filter.shadowBias = filter.shadowBias + Float(0.15 + 0.55 * a)
        // Mild baseline lift opens crushed toe on Base-100 punch without a global EV wash.
        filter.baselineExposure = filter.baselineExposure + Float(0.08 + 0.35 * a)
        if filter.isDetailSupported {
            filter.detailAmount = max(filter.detailAmount, Float(0.70 + 0.25 * a))
        }
        if filter.isContrastSupported {
            // Keep some microcontrast so the recover layer isn’t milky gray.
            filter.contrastAmount = max(filter.contrastAmount, Float(0.12 + 0.10 * a))
        }
    }

    nonisolated private static func ciImage(from nsImage: NSImage) -> CIImage? {
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

    /// CIRAW defaults for Flip / Grade-zero.
    /// Base 100 ≈ as-shot CIRAW (plus highlight recovery when available) — don't soft-cap
    /// contrast or force tonemap; that just makes Flip look dimmer than the camera JPEG.
    /// Softer Base / recover still opens tone-curve headroom via boost + baseline/shadows.
    /// Note: local tone map is unsupported on some cameras (e.g. Panasonic RW2).
    nonisolated private static func applyHighlightFriendlyDefaults(
        to filter: CIRAWFilter,
        boostAmount: Double
    ) {
        if #available(macOS 26.0, *) {
            if filter.isHighlightRecoverySupported {
                filter.isHighlightRecoveryEnabled = true
            }
        }
        let boost = min(1, max(0, boostAmount))
        filter.boostAmount = Float(boost)

        let headroom = 1.0 - boost
        guard headroom > 0.0001 else { return }

        if filter.isContrastSupported {
            filter.contrastAmount = max(0, min(filter.contrastAmount, 0.15))
        }
        if filter.isLocalToneMapSupported {
            filter.localToneMapAmount = max(filter.localToneMapAmount, 0.62)
        }
        if filter.isDetailSupported {
            filter.detailAmount = max(filter.detailAmount, 0.55)
        }
        filter.baselineExposure = filter.baselineExposure - Float(0.32 * headroom)
        filter.boostShadowAmount = min(
            2.0,
            filter.boostShadowAmount + Float(0.06 + 0.10 * headroom)
        )
    }

    /// ImageIO path for non-RAW / unsupported cameras — still tagged into outputColorSpace.
    nonisolated private static func demosaicImageIO(url: URL, maxPixelSize: CGFloat?) -> RAWRenderResult? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ]
        if let maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // Re-render through CI so fallback lands in the same tagged space as CIRAW.
        let ciImage = CIImage(cgImage: cg)
        // ImageIO thumb is already at the requested size — treat as full for that request.
        return makeResult(rendering: ciImage, scaleFactor: 1)
    }

    nonisolated private static func makeResult(rendering ciImage: CIImage, scaleFactor: CGFloat) -> RAWRenderResult? {
        let rect = ciImage.extent.integral
        guard rect.width > 1, rect.height > 1 else { return nil }
        guard let cg = ciContext.createCGImage(
            ciImage,
            from: rect,
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else { return nil }

        let renderedW = cg.width
        let renderedH = cg.height
        let scale = max(scaleFactor, 0.0001)
        let fullW = max(1, Int((CGFloat(renderedW) / scale).rounded()))
        let fullH = max(1, Int((CGFloat(renderedH) / scale).rounded()))

        guard let image = nsImage(from: cg, width: renderedW, height: renderedH) else { return nil }
        return RAWRenderResult(
            image: image,
            renderedWidth: renderedW,
            renderedHeight: renderedH,
            fullWidth: fullW,
            fullHeight: fullH
        )
    }

    /// 1 point = 1 pixel — required so Space zoom (`pixelSize` × 1/backingScale) stays true 1:1.
    nonisolated private static func nsImage(from cg: CGImage, width: Int, height: Int) -> NSImage? {
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: width, height: height)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        // Keep the CGImage's Display P3 tag available to AppKit/SwiftUI.
        return image
    }
}
