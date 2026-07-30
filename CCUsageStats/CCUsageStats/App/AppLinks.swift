import Foundation

/// Outbound links to the project's own pages.
enum AppLinks {
    static let repository = "https://github.com/dmytro-vovk/cc-usage-stats"

    /// The releases *index*, deliberately not the running version's own tag
    /// page: builds that don't go through `scripts/build.sh` report 0.0.0,
    /// which has no tag and would 404. The index is correct for every build.
    static let releases = URL(string: "\(repository)/releases")!
}
