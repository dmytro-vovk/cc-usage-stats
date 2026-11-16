import Foundation

/// Which outage the user closed the banner on, and whether the current one
/// is still that outage.
///
/// An outage is identified by its unresolved Statuspage incident IDs, or,
/// when the page is degraded with no incident attached, by severity plus
/// summary. A dismissal lasts while its key stays active: once a key drops
/// out of a report it is forgotten, so the same incident clearing and
/// coming back counts as new.
enum OutageDismissal {
    static func keys(for report: StatusReport?) -> Set<String> {
        guard let r = report else { return [] }
        // An unresolved incident keeps its key even when the page-level
        // indicator reads operational (e.g. while it's being monitored):
        // it hasn't cleared, so its dismissal must survive that poll.
        if !r.activeIncidentIDs.isEmpty {
            return Set(r.activeIncidentIDs.map { "incident:\($0)" })
        }
        guard r.indicator != .none else { return [] }
        return ["status:\(r.indicator.rawValue):\(r.description)"]
    }

    /// True when there is an outage and every part of it was dismissed.
    static func isDismissed(_ report: StatusReport?, dismissed: Set<String>) -> Bool {
        let current = keys(for: report)
        return !current.isEmpty && current.isSubset(of: dismissed)
    }

    /// Drops dismissed keys the report no longer carries.
    static func pruned(_ dismissed: Set<String>, for report: StatusReport) -> Set<String> {
        dismissed.intersection(keys(for: report))
    }
}
