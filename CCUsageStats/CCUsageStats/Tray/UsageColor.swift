import SwiftUI
import AppKit

/// Perceptually uniform color gradient for utilization 0..1 via OKLab.
///
/// Below 50% the icon stays flat green; the gradient kicks in for the
/// upper half of the range.
///
/// Anchors come in two flavours so the same call site reads well in
/// both light and dark mode:
///   - **dark mode** uses Apple's brighter system{Green,Orange,Red}
///     (52,199,89 / 255,149,0 / 255,59,48), which sit cleanly on dark
///     surfaces.
///   - **light mode** uses the slightly darker / more saturated variants
///     Apple ships for the light appearance (40,180,78 / 245,135,0 /
///     230,40,30), which read better against white menubars / dropdown
///     backgrounds without losing meaning.
enum UsageColor {
    private struct Anchors {
        let green:  (Double, Double, Double)
        let orange: (Double, Double, Double)
        let red:    (Double, Double, Double)
    }

    private static let dark = Anchors(
        green:  (52,  199, 89),
        orange: (255, 149, 0),
        red:    (255, 59,  48)
    )
    private static let light = Anchors(
        green:  (40,  180, 78),
        orange: (245, 135, 0),
        red:    (230, 40,  30)
    )

    /// SwiftUI entry point — picks anchors for the given environment.
    static func gradient(t rawT: Double, scheme: ColorScheme = .dark) -> Color {
        let (r, g, b) = rgb(t: rawT, anchors: scheme == .dark ? dark : light)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    /// AppKit entry point for the menubar's NSImage rendering. Picks
    /// anchors from the running app's effective appearance.
    static func nsColor(t rawT: Double) -> NSColor {
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let (r, g, b) = rgb(t: rawT, anchors: isDark ? dark : light)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - core math

    private static func rgb(t rawT: Double, anchors: Anchors) -> (Double, Double, Double) {
        let t = max(0.0, min(1.0, rawT))
        if t <= 0.5 {
            return (anchors.green.0 / 255.0,
                    anchors.green.1 / 255.0,
                    anchors.green.2 / 255.0)
        }
        let u = (t - 0.5) * 2.0
        let g = rgbToOklab(anchors.green)
        let o = rgbToOklab(anchors.orange)
        let r = rgbToOklab(anchors.red)
        let (a, b, segT): ([Double], [Double], Double) = u < 0.5
            ? (g, o, u * 2.0)
            : (o, r, (u - 0.5) * 2.0)
        let lab = [lerp(a[0], b[0], segT), lerp(a[1], b[1], segT), lerp(a[2], b[2], segT)]
        let (rr, gg, bb) = oklabToRgb(L: lab[0], a: lab[1], b: lab[2])
        return (rr, gg, bb)
    }

    // MARK: - OKLab conversions

    private static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    private static func rgbToOklab(_ rgb: (Double, Double, Double)) -> [Double] {
        let lr = srgbToLinear(rgb.0 / 255.0)
        let lg = srgbToLinear(rgb.1 / 255.0)
        let lb = srgbToLinear(rgb.2 / 255.0)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return [
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        ]
    }

    private static func oklabToRgb(L: Double, a: Double, b: Double) -> (Double, Double, Double) {
        let lL = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let mM = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let sS = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r =  4.0767416621 * lL - 3.3077115913 * mM + 0.2309699292 * sS
        let g = -1.2684380046 * lL + 2.6097574011 * mM - 0.3413193965 * sS
        let bb = -0.0041960863 * lL - 0.7034186147 * mM + 1.7076147010 * sS
        return (
            max(0.0, min(1.0, linearToSrgb(r))),
            max(0.0, min(1.0, linearToSrgb(g))),
            max(0.0, min(1.0, linearToSrgb(bb)))
        )
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}
