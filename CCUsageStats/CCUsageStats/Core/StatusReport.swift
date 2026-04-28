import Foundation

/// Snapshot of status.claude.com (Atlassian Statuspage) at a point in time.
struct StatusReport: Equatable {
    enum Indicator: String, Equatable {
        case none, minor, major, critical, maintenance
    }

    let indicator: Indicator
    /// Human-readable summary, e.g. "All Systems Operational" or
    /// "Partial System Outage".
    let description: String
    /// Title of the most recent unresolved incident, if any.
    let activeIncident: String?

    static let allOperational = StatusReport(
        indicator: .none,
        description: "All Systems Operational",
        activeIncident: nil
    )

    /// Parses the body of `https://status.claude.com/api/v2/summary.json`.
    /// Returns nil for malformed JSON or missing required fields.
    static func parse(summaryJSON data: Data) -> StatusReport? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let status = obj["status"] as? [String: Any],
              let raw = status["indicator"] as? String,
              let description = status["description"] as? String else {
            return nil
        }
        // "maintenance" can also appear at component level; treat it as
        // its own bucket only when the page-level indicator says so.
        let indicator = Indicator(rawValue: raw) ?? .none

        // Newest non-resolved incident.
        let incidents = (obj["incidents"] as? [[String: Any]]) ?? []
        let active = incidents.first { incident in
            let s = (incident["status"] as? String) ?? ""
            return s != "resolved" && s != "postmortem"
        }
        let title = active?["name"] as? String

        return StatusReport(indicator: indicator, description: description, activeIncident: title)
    }
}
