import Foundation

struct PillSegment: Equatable {
    enum Kind: Equatable {
        case fiveHour
        case sevenDay
        case model(String)
    }

    let kind: Kind
    /// 0..1, clamped.
    let fraction: Double
    let text: String
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
        now: Int64
    ) -> [PillSegment] {
        guard let five else { return [] }
        let fiveFraction = clamp(five.usedPercentage / 100.0)
        var result = [PillSegment(kind: .fiveHour, fraction: fiveFraction, text: fiveText)]

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
                    kind: .sevenDay, fraction: f, text: percentText(seven.usedPercentage)
                ))
            }
        }

        // Independent of whether 7d qualified: the model window is a
        // separate limit and can be the only one in trouble.
        //
        // Expired windows are excluded. Model windows are merged per key and
        // never deleted from the cache, so a user who disconnects their
        // account leaves a frozen value behind — without this guard it would
        // claim menubar space forever with data nothing can refresh.
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
                    kind: .model(top.0), fraction: f, text: percentText(top.1.usedPercentage)
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
