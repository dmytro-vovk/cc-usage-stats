import Foundation

/// Outbound links to the project's own pages.
enum AppLinks {
    /// The project site, whose download button points at the latest release.
    /// Everything in the dropdown that leads out opens this: the footer's
    /// version label, "Update available" and the update notification. Not a
    /// per-version page: builds that don't go through `scripts/build.sh`
    /// report 0.0.0, which has none.
    nonisolated static let website = URL(string: "https://ccusagestats.app/")!
}
