import Foundation

/// Why an install, update or move to the Trash did not happen, with the step or check that stopped it, as the `subset`
/// command names them (packages/subset-dev/src/macos/install.mjs and verify.mjs).
public struct InstallFailure: Error, Equatable, Sendable {
    public enum Step: String, Sendable {
        // The steps of an install (InstallError in install.mjs).
        case destination, download, checksum, image, copy, install, receipt
        // The checks of the staged copy (VerificationError in verify.mjs).
        case signature, team, notarization, bundleID = "bundle ID", version, macOSVersion = "macOS version"
        // Refusals before anything is changed, and the Trash.
        case running, lock, downgrade, notInstalled = "not installed", trash
        // Stopped by the user (Cancel) or the app quitting, before anything was installed.
        case interrupted
    }

    public var step: Step
    public var message: String
    /// Whether the operation had already changed a copy (updated, moved aside or moved one, or put back what an
    /// interrupted one had left) when it stopped. Asking an app to quit changes no copy; the notes say it.
    public var partial = false
    /// Whether putting back or renaming what an interrupted operation had left was all it changed: the update or move
    /// itself did not run.
    public var onlyRecovered = false
    /// The notes it had collected, with what it had changed when `partial`.
    public var notes: [String] = []

    public init(_ step: Step, _ message: String) {
        self.step = step
        self.message = message
    }

    static let verificationChecks: Set<Step> = [.signature, .team, .notarization, .bundleID, .version, .macOSVersion]

    /// The failure as one plain sentence after "<App> was not installed: ".
    public var explanation: String {
        switch step {
        case _ where Self.verificationChecks.contains(step): return "the \(step.rawValue) check failed: \(message)"
        case .destination, .download, .checksum, .image, .copy, .install, .receipt: return "the \(step.rawValue) step failed: \(message)"
        default: return message
        }
    }
}

/// The release of one channel that an install or update puts in place.
public struct ChosenRelease: Equatable, Sendable {
    public var channel: ReleaseChannel
    public var version: String
    /// The beta build; nil for a live release.
    public var build: Int?
    public var url: String
    public var sha256: String

    /// The channel's release of `app`, or nil when it has none.
    public init?(_ app: CatalogApp, channel: ReleaseChannel) {
        self.channel = channel
        switch channel {
        case .live:
            guard let live = app.live else { return nil }
            (version, build, url, sha256) = (live.version, nil, live.url, live.sha256)
        case .beta:
            guard let beta = app.beta else { return nil }
            (version, build, url, sha256) = (beta.version, beta.build, beta.url, beta.sha256)
        }
    }

    /// 0.1.0, or 0.1.1-beta.4 for a beta, as `subset list` shows it.
    public var label: String { build.map { "\(version)-beta.\($0)" } ?? version }
}

/// What an operation reports while it runs, for the row's progress.
public enum InstallProgress: Equatable, Sendable {
    /// Bytes received, and the total when the server sent it.
    case downloading(received: Int64, total: Int64?)
    case verifying
    case quitting
    case installing
    case movingToTrash
}
