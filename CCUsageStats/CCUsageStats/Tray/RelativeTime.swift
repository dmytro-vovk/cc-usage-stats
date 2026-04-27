import Foundation

enum RelativeTime {
    static func format(seconds raw: Int64) -> String {
        let s = max(0, raw)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let remM = m % 60
        if h < 24 { return "\(h)h \(remM)m" }
        let d = h / 24
        let remH = h % 24
        return "\(d)d \(remH)h"
    }

    /// Digital-clock style for the menubar countdown when at 100%.
    /// Always shows H:MM:SS (e.g. `1:30:45`, `0:00:09`).
    static func formatHMS(seconds raw: Int64) -> String {
        let s = max(0, raw)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%d:%02d:%02d", h, m, sec)
    }
}
