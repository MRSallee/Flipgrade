import Foundation

/// Non-destructive develop settings for one photo.
/// Applied through `DevelopPipeline` on top of `RAWRender`.
struct EditRecipe: Codable, Equatable, Sendable {
    var version: Int = 2

    /// White balance temperature in Kelvin. `0` = as-shot (no change).
    /// UI: 2000…50000 (Camera Raw–style).
    var temperature: Double = 0
    /// Tint in Camera Raw–like units (−150…+150). `0` = as-shot.
    var tint: Double = 0
    /// EV stops (−5…+5). Applied in CIRAW when possible for highlight headroom.
    var exposure: Double = 0
    /// −1…+1 contrast.
    var contrast: Double = 0
    /// −1…+1; positive brightens highlights, negative recovers.
    var highlights: Double = 0
    /// −1…+1; positive lifts shadows, negative crushes.
    var shadows: Double = 0
    /// Runtime-only mid lift after CIRAW Highlights recover (not persisted).
    /// Raises 0.15…0.65 luma without touching the recovered shoulder.
    var midtoneFill: Double = 0

    static let identity = EditRecipe()

    var isIdentity: Bool {
        abs(temperature) < 0.0001
            && abs(tint) < 0.0001
            && abs(exposure) < 0.0001
            && abs(contrast) < 0.0001
            && abs(highlights) < 0.0001
            && abs(shadows) < 0.0001
            && abs(midtoneFill) < 0.0001
    }

    enum CodingKeys: String, CodingKey {
        case version, temperature, tint, exposure, contrast, highlights, shadows
    }

    init(
        version: Int = 2,
        temperature: Double = 0,
        tint: Double = 0,
        exposure: Double = 0,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        midtoneFill: Double = 0
    ) {
        self.version = version
        self.temperature = temperature
        self.tint = tint
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.midtoneFill = midtoneFill
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0

        if decodedVersion < 2 {
            // v1 used relative −1…+1 WB — drop rather than mis-read as Kelvin.
            version = 2
            temperature = 0
            tint = 0
        } else {
            version = decodedVersion
            temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
            tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        }
        midtoneFill = 0
    }

    /// Clears CIRAW-baked WB/EV. Negative Highlights / positive Shadows are zeroed when
    /// dual demosaic owns them (caller zeros +Shadows only after a successful SH blend).
    var afterCIRAWBake: EditRecipe {
        var copy = self
        copy.temperature = 0
        copy.tint = 0
        copy.exposure = 0
        copy.midtoneFill = 0
        if copy.highlights < 0 {
            copy.highlights = 0
        }
        return copy
    }

    /// Low CIRAW boost for the *recover* demosaic layer (blended into punch by luma mask).
    /// Ladder dumps: recover had more HL structure than punch but still clipped lamp cores —
    /// match Base 0 (which recovers hat/fluorescent) at Highlights −1.
    func cirawBoostAmount(baseBoost: Double) -> Double {
        let base = min(1, max(0, baseBoost))
        let recover = min(1, max(0, -highlights))
        // −1.0 → 0% of Base (same as Base slider 0).
        return base * (1.0 - recover)
    }

    /// Do not bake +EV for Highlights recover — it undoes boost headroom and re-clips.
    func cirawHighlightRecoverEV() -> Double { 0 }

    /// CIRAW `shadowOpen` for the +Shadows recover demosaic (0…1).
    /// UI +1 targets ACR +100 — sensor-path toe open, not a post LUT.
    func cirawShadowOpenAmount() -> Double {
        min(1, max(0, shadows))
    }

    /// Legacy alias — prefer `afterCIRAWBake` when exposure is also baked.
    var toneOnly: EditRecipe { afterCIRAWBake }
}

/// Shared WB slider limits (Camera Raw–familiar).
enum WhiteBalanceLimits {
    /// Adobe Camera Raw–style Temperature endpoints.
    static let kelvinRange: ClosedRange<Double> = 2000...50_000
    static let tintRange: ClosedRange<Double> = -150...150
    static let defaultAsShotKelvin: Double = 5500
    static let defaultAsShotTint: Double = 0
}

enum ExposureLimits {
    static let evRange: ClosedRange<Double> = -5...5
}

/// How exposure/contrast are applied. App-wide preference (not per-photo).
enum DevelopColorMode: String, CaseIterable, Codable, Sendable {
    case lab
    case rgb

    var label: String {
        switch self {
        case .lab: return "Tone in LAB"
        case .rgb: return "Tone in RGB"
        }
    }
}

@MainActor
enum DevelopPrefs {
    private static let modeKey = "flipgrade.developColorMode"
    private static let baseBoostKey = "flipgrade.developBaseBoost.v2"

    /// CIRAW `boostAmount` default — full punch (1.0) for ACR-comparable benchmarking.
    /// Soften via the Base slider when you want highlight headroom.
    static let defaultBaseBoost: Double = 1.0
    static let baseBoostRange: ClosedRange<Double> = 0...1

    static var colorMode: DevelopColorMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modeKey),
                  let mode = DevelopColorMode(rawValue: raw)
            else { return .lab }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
        }
    }

    /// Global CIRAW tone-curve strength (0 = linear / soft, 1 = full punch).
    static var baseBoost: Double {
        get {
            if UserDefaults.standard.object(forKey: baseBoostKey) == nil {
                return defaultBaseBoost
            }
            let v = UserDefaults.standard.double(forKey: baseBoostKey)
            return min(baseBoostRange.upperBound, max(baseBoostRange.lowerBound, v))
        }
        set {
            let v = min(baseBoostRange.upperBound, max(baseBoostRange.lowerBound, newValue))
            UserDefaults.standard.set(v, forKey: baseBoostKey)
        }
    }
}
