import Foundation

struct PillSegment: Equatable {
    enum Kind: Equatable {
        case fiveHour
        case sevenDay
        case model(String)
        case codex
    }

    let kind: Kind
    /// 0..1, clamped.
    let fraction: Double
    let text: String
    /// No data behind this band: drawn grey instead of on the usage ramp.
    var dimmed: Bool = false
    /// Where on the colour ramp to paint, when that differs from `fraction`
    /// (colour by pace). `fraction` still drives layout and the gauge.
    var colorFraction: Double? = nil

    var paintFraction: Double { colorFraction ?? fraction }
}

/// Decides which windows share the menubar pill.
///
/// Pure so the gating matrix is testable without AppKit. Reachable states:
/// `5h`, `5h│7d`, `5h│model`, `5h│7d│model`.
enum PillLayout {
    /// A window must be this far along before it earns menubar space.
    static let promoteThreshold = 0.8

    static func segments(
        five: WindowSnapshot?,
        seven: WindowSnapshot?,
        models: [String: WindowSnapshot],
        fiveText: String,
        authState: AuthState,
        now: Int64,
        coloring: UsageColoring = .absolute
    ) -> [PillSegment] {
        guard let five else { return [] }
        let fiveFraction = clamp(five.usedPercentage / 100.0)
        var result = [PillSegment(
            kind: .fiveHour, fraction: fiveFraction, text: fiveText,
            colorFraction: coloring.paint(five, windowLength: UsageColoring.fiveHourLength, now: now)
        )]

        // No usable token renders a bare triangle; at cap the 5h half shows a
        // countdown that is wide enough on its own. Neither shares the pill.
        // `lacksWorkingToken` covers both .noToken and .invalidToken — the
        // distinction matters for the copy shown, not for pill layout.
        guard !authState.lacksWorkingToken, fiveFraction < 1.0 else { return result }

        func qualifies(_ fraction: Double) -> Bool {
            fraction > promoteThreshold && fraction >= fiveFraction
        }

        if let seven {
            let f = clamp(seven.usedPercentage / 100.0)
            if qualifies(f) {
                result.append(.init(
                    kind: .sevenDay, fraction: f, text: percentText(seven.usedPercentage),
                    colorFraction: coloring.paint(seven, windowLength: UsageColoring.weekLength, now: now)
                ))
            }
        }

        // Independent of whether 7d qualified: the model window is a
        // separate limit and can be the only one in trouble.
        //
        // Expired windows are excluded. `CacheStore.update` now drops model
        // windows the moment a source that cannot see them writes, so the
        // "frozen after disconnect" case this guard was written for is gone
        // at the source. It still earns its keep for the case the cache
        // cannot fix: a window the endpoint keeps reporting past its own
        // `resets_at`, which would otherwise claim menubar space for a
        // period that has already ended.
        let candidates = UsageWindows.orderedModelKeys(models)
            .compactMap { key -> (String, WindowSnapshot)? in
                guard let w = models[key], w.resetsAt > now else { return nil }
                return (key, w)
            }
        let top = candidates.max { $0.1.usedPercentage < $1.1.usedPercentage }
        if let top {
            let f = clamp(top.1.usedPercentage / 100.0)
            if qualifies(f) {
                result.append(.init(
                    kind: .model(top.0), fraction: f, text: percentText(top.1.usedPercentage),
                    colorFraction: coloring.paint(top.1, windowLength: UsageColoring.weekLength, now: now)
                ))
            }
        }

        return result
    }

    private static func clamp(_ v: Double) -> Double { max(0.0, min(1.0, v)) }

    /// Text reports the raw server percentage; only the color fraction is
    /// clamped. Matches the pre-existing 7d rendering.
    private static func percentText(_ percentage: Double) -> String {
        "\(Int(percentage.rounded()))%"
    }
}

/// What the menubar pill shows. Persisted; set on the General settings tab.
enum PillMode: String, CaseIterable, Identifiable {
    case claude, codex, both

    static let defaultsKey = "cc-usage-stats.pillMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .both: return "Both"
        }
    }

    static func read(from defaults: UserDefaults = .standard) -> PillMode {
        defaults.string(forKey: defaultsKey).flatMap(PillMode.init(rawValue:)) ?? .claude
    }
}

/// How the label should be drawn: Claude's own rendering, untouched, or an
/// explicit list of bands.
enum PillPlan: Equatable {
    case claude
    case segments([PillSegment])
}

/// Combines the Claude pill with Codex according to `PillMode`.
///
/// `.claude` hands back to the existing rendering (single pill, warning
/// triangle, split pill) so the Claude-only pill is byte-for-byte what it was.
enum PillComposer {
    static func plan(
        mode: PillMode,
        codexTracking: Bool,
        claudeSegments: [PillSegment],
        claudeLacksWorkingToken: Bool,
        codex: CodexSnapshot?,
        now: Int64,
        coloring: UsageColoring = .absolute
    ) -> PillPlan {
        guard codexTracking else { return .claude }
        switch mode {
        case .claude:
            return .claude
        case .codex:
            return .segments([codexSegment(codex, now: now, coloring: coloring)
                ?? PillSegment(kind: .codex, fraction: 0, text: "—", dimmed: true)])
        case .both:
            // A Claude token problem renders as the red triangle; hiding it
            // behind a healthy Codex band would bury the thing to fix.
            guard !claudeLacksWorkingToken, let codexSeg = codexSegment(codex, now: now, coloring: coloring) else {
                return .claude
            }
            return .segments(claudeSegments + [codexSeg])
        }
    }

    /// Painted at the most worrying window's colour, which under pace
    /// colouring need not be the fullest one.
    static func codexSegment(_ codex: CodexSnapshot?, now: Int64, coloring: UsageColoring = .absolute) -> PillSegment? {
        guard let codex, let peak = codex.peakPercent(now: now) else { return nil }
        let paint = codex.windows.map {
            coloring.fraction(
                usedPercent: $0.effectivePercent(now: now), resetsAt: $0.resetsAt,
                windowLength: Int64($0.windowMinutes) * 60, now: now
            )
        }.max()
        return PillSegment(kind: .codex, fraction: max(0, min(1, peak / 100)), text: "\(Int(peak.rounded()))%",
                           colorFraction: coloring.byPace ? paint : nil)
    }
}
