import Foundation

/// A `vMAJOR.MINOR.PATCH` version, as the release tags and
/// `CFBundleShortVersionString` spell it. Missing components count as zero;
/// a `-pre.release` suffix sorts below the bare version (semver), and
/// `+build` metadata is ignored.
nonisolated struct AppVersion: Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Non-empty for a pre-release (`1.0.0-beta.1`). Pre-releases compare by
    /// this string only against each other, which is enough to place them
    /// below their release.
    let preRelease: String

    init(major: Int, minor: Int, patch: Int, preRelease: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    init?(_ raw: String) {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre = ""
        if let dash = s.firstIndex(of: "-") {
            pre = String(s[s.index(after: dash)...])
            s = s[..<dash]
            if pre.isEmpty { return nil }
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], preRelease: pre)
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        switch (a.preRelease.isEmpty, b.preRelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): return a.preRelease < b.preRelease
        }
    }

    var description: String {
        "\(major).\(minor).\(patch)" + (preRelease.isEmpty ? "" : "-\(preRelease)")
    }
}

/// The newest published release, from GitHub's `releases/latest`.
///
/// Only its tag: nothing in the app links to GitHub. Every "there is an
/// update" link opens `AppLinks.website`, a constant, so no URL from the
/// response is ever followed.
nonisolated struct LatestRelease: Equatable {
    let tag: String
    let version: AppVersion

    /// `nil` for anything that isn't a usable published release: drafts,
    /// pre-releases and tags that aren't versions.
    static func parse(_ data: Data) -> LatestRelease? {
        struct Payload: Decodable {
            let tag_name: String
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              p.draft != true, p.prerelease != true,
              let version = AppVersion(p.tag_name), version.preRelease.isEmpty else { return nil }
        return LatestRelease(tag: p.tag_name, version: version)
    }
}
