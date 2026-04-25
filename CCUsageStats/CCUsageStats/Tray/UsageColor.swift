import SwiftUI

/// Perceptually uniform color gradient for utilization 0..1 via OKLab.
///
/// Below 50% the icon stays flat green; the gradient only kicks in for the
/// upper half of the range. Anchors:
///   t in [0.0, 0.5] → Apple system green  (52, 199, 89)
///   t = 0.75        → Apple system orange (255, 149, 0)
///   t = 1.0         → Apple system red    (255, 59, 48)
enum UsageColor {
    /// Returns the gradient color for a utilization fraction `t` in `[0, 1]`.
    /// Out-of-range inputs are clamped.
    static func gradient(t rawT: Double) -> Color {
        let t = max(0.0, min(1.0, rawT))

        // Flat green for the first half.
        if t <= 0.5 {
            return Color(.sRGB, red: 52.0/255.0, green: 199.0/255.0, blue: 89.0/255.0, opacity: 1.0)
        }

        // Remap [0.5, 1.0] -> [0.0, 1.0] across green -> orange -> red.
        let u = (t - 0.5) * 2.0
        let green  = rgbToOklab(r: 52,  g: 199, b: 89)
        let orange = rgbToOklab(r: 255, g: 149, b: 0)
        let red    = rgbToOklab(r: 255, g: 59,  b: 48)

        let (a, b, segT): ([Double], [Double], Double) = u < 0.5
            ? (green, orange, u * 2.0)
            : (orange, red, (u - 0.5) * 2.0)
        let lab = [lerp(a[0], b[0], segT), lerp(a[1], b[1], segT), lerp(a[2], b[2], segT)]
        let (rr, gg, bb) = oklabToRgb(L: lab[0], a: lab[1], b: lab[2])
        return Color(.sRGB, red: rr, green: gg, blue: bb, opacity: 1.0)
    }

    // MARK: - OKLab conversions
    // Reference: https://bottosson.github.io/posts/oklab/

    private static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    private static func rgbToOklab(r: Double, g: Double, b: Double) -> [Double] {
        let lr = srgbToLinear(r / 255.0)
        let lg = srgbToLinear(g / 255.0)
        let lb = srgbToLinear(b / 255.0)
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
