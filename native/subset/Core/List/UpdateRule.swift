/// Whether a channel has a newer release than an installed copy, by the rule `subset update` uses to decide what it
/// would do (`decideUpdate` in packages/subset-dev/src/macos/update.mjs).
public enum UpdateRule {
    public enum Decision: Equatable, Sendable {
        /// The channel's version is newer; or, at the same version, the copy is a beta by its receipt and this is the
        /// live release; or a beta with a newer build.
        case update
        /// The same release.
        case current
        /// The copy is newer than the channel.
        case ahead
        /// The copy's version is not x.y.z, so it cannot be compared.
        case unknown
        /// The app has no release on this channel.
        case noRelease
    }

    public static func decide(_ copy: InstalledCopy, _ app: CatalogApp, channel: ReleaseChannel) -> Decision {
        let version: String
        switch channel {
        case .live:
            guard let live = app.live else { return .noRelease }
            version = live.version
        case .beta:
            guard let beta = app.beta else { return .noRelease }
            version = beta.version
        }
        guard let copyVersion = copy.version, FeedPattern.version.matches(copyVersion) else { return .unknown }
        let order = compareVersions(version, copyVersion)
        if order != 0 { return order > 0 ? .update : .ahead }
        guard channel == .beta, let beta = app.beta else { return copy.channel == .beta ? .update : .current }
        // A beta channel at the same version: only a beta (by its receipt) compares builds; the live release of a
        // version is not older than its betas.
        guard copy.channel == .beta, let build = copy.build, isDecimal(build) else { return .current }
        let builds = compareNumbers(String(beta.build), build)
        return builds > 0 ? .update : builds < 0 ? .ahead : .current
    }

    /// Compares two decimal numbers of any size exactly: -1, 0 or 1. Each must be ASCII digits only.
    static func compareNumbers(_ a: String, _ b: String) -> Int {
        let left = a.drop { $0 == "0" }
        let right = b.drop { $0 == "0" }
        if left.count != right.count { return left.count < right.count ? -1 : 1 }
        if left == right { return 0 }
        return left < right ? -1 : 1
    }

    /// Compares two x.y.z versions exactly, whatever the size of their parts: -1, 0 or 1.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        for (left, right) in zip(a.split(separator: "."), b.split(separator: ".")) {
            let order = compareNumbers(String(left), String(right))
            if order != 0 { return order }
        }
        return 0
    }

    private static func isDecimal(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}
