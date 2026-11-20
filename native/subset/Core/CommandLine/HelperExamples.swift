import Combine
import Darwin
import Foundation

/// A command an installed app bundles, as the Command Line section shows it.
public struct HelperExample: Equatable, Identifiable, Sendable {
    public var id: String { command }
    /// The app's name in the feed.
    public var appName: String
    /// The feed helper's command: `subset <command>` runs it.
    public var command: String
    /// A command line to copy, such as `subset system status`.
    public var example: String
    /// Where the instructions for agents are, in the command's README.
    public var guide: URL
    /// Whether the copy `subset` runs (the first in /Applications, then ~/Applications) has nothing at the helper's path,
    /// which `subset` takes for an older copy (`isMissing`). A helper that is there, or a path `subset` refuses, is
    /// checked by `subset` itself (a file inside the app, signed by Subset), which the section does not claim.
    public var missingFromCopy: Bool
    /// Whether `subset` then runs the command's npm package instead (Timer, Minutes); otherwise it asks for an update.
    public var npmFallback: Bool
}

/// The examples for the bundled commands of installed apps, from the feed's `helpers`.
public enum HelperExamples {
    /// The one-line setup the section offers to copy. The app never runs it.
    public static let setupCommand = "npm i -g subset.dev"
    static let repository = "https://github.com/21nCo/subset/blob/dev/"
    /// Every bundled command's section in `packages/subset-dev/README.md`, for a command without a guide of its own.
    static let fallbackGuide = "packages/subset-dev/README.md#commands-bundled-in-mac-apps"
    /// `subset` runs the commands Mac apps bundle (SET-232) from 0.2.0 on; an older release runs Timer and Minutes from
    /// npm only and knows no app-only command.
    public static let minimumLauncherVersion = "0.2.0"

    /// The read-only example and the agent instructions of each command the apps bundle today (docs/macos-release.md).
    /// `subset timer` lists the timers, since `status` needs a timer. `npm`: the command also has an npm package.
    static let known: [String: (arguments: String, guide: String, npm: Bool)] = [
        "timer": ("list", "packages/timer-cli/README.md#agent-skill", true),
        "minutes": ("status", "packages/minutes-cli/README.md#json-output-for-agents-and-apps", true),
        "system": ("status", "native/system/README.md#agent-helper", false),
        "point-in-time": ("status", "native/point-in-time/README.md#command-line-status-for-agents", false),
    ]

    /// One example per helper of each feed app with an installed copy, in feed order. A helper the table above does not
    /// know shows `subset <command> --help` and the bundled commands' section of the `subset.dev` README. `isMissing`
    /// tells whether a helper path is missing in the first copy, which `subset` runs.
    public static func examples(
        apps: [CatalogApp], installed: [String: [InstalledCopy]], isMissing: (String, String) -> Bool = HelperExamples.isMissing
    ) -> [HelperExample] {
        apps.compactMap { app in installed[app.id]?.first.map { (app, $0) } }.flatMap { app, copy in
            app.helpers.map { helper in
                let known = known[helper.command]
                return HelperExample(
                    appName: app.name, command: helper.command,
                    example: "subset \(helper.command) \(known?.arguments ?? "--help")",
                    guide: URL(string: repository + (known?.guide ?? fallbackGuide))!,
                    missingFromCopy: isMissing(copy.path, helper.path), npmFallback: known?.npm ?? false
                )
            }
        }
    }

    /// Whether nothing is at `relative` in `bundle` as `subset` decides an older copy (`helperFile` in
    /// packages/subset-dev/src/helpers.mjs): each part before the absent one leads, with its links resolved, to a folder
    /// inside the bundle's Contents. A link that leads out of Contents or nowhere, a file where a folder should be, or a
    /// part that cannot be read is refused by `subset`, not missing. It reads the file system: call it off the main thread.
    public static func isMissing(_ bundle: String, _ relative: String) -> Bool {
        guard var real = realPath(bundle) else { return false }
        let contents = real + "/Contents/"
        let parts = relative.split(separator: "/")
        for (index, part) in parts.enumerated() {
            let entry = real + "/" + part
            var status = stat()
            guard lstat(entry, &status) == 0 else { return errno == ENOENT }
            guard let resolved = realPath(entry), (resolved + "/").hasPrefix(contents) else { return false }
            real = resolved
            guard index == parts.count - 1 || (stat(real, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR) else { return false }
        }
        return false
    }

    /// `path` with its links resolved, or nil when it leads nowhere.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `subset` at `version` is older than `minimumLauncherVersion`, so it runs no bundled command. From that
    /// version on, its betas included, the version alone does not tell which commands it knows, so nothing is claimed.
    public static func predatesBundledCommands(_ version: String) -> Bool {
        func core(_ version: String) -> [Int] {
            version.prefix { $0 != "-" && $0 != "+" }.split(separator: ".").map { Int($0) ?? 0 }
        }
        return core(version).lexicographicallyPrecedes(core(minimumLauncherVersion))
    }
}

/// The Command Line section's examples. They are shown at once; whether each helper is missing from its copy is looked
/// up on a thread of its own, never the main thread (a stalled volume would freeze the window), and shown when known.
/// `update` is called whenever the installed apps are looked for again (after an install, update or move to the Trash).
/// At most `maxLookups` lookups run at once, so a stalled volume holds no more threads; the newest one asked for while
/// they run starts when one ends, and an older lookup never replaces a newer one's result.
@MainActor
public final class HelperExamplesModel: ObservableObject {
    public static let maxLookups = 2

    @Published public private(set) var examples: [HelperExample] = []

    private let isMissing: @Sendable (String, String) -> Bool
    private var apps: [CatalogApp] = []
    private var installed: [String: [InstalledCopy]] = [:]
    /// Whether each helper path (bundle, NUL, relative path) is missing, from the newest lookup that ended.
    private var missing: [String: Bool] = [:]
    private var asked = 0
    private var shown = 0
    private var running = 0
    private var pending: (number: Int, paths: [(String, String)])?

    public init(isMissing: @escaping @Sendable (String, String) -> Bool = HelperExamples.isMissing) {
        self.isMissing = isMissing
    }

    public func update(apps: [CatalogApp], installed: [String: [InstalledCopy]]) {
        self.apps = apps
        self.installed = installed
        var paths: [(String, String)] = []
        _ = HelperExamples.examples(apps: apps, installed: installed) { paths.append(($0, $1)); return false }
        asked += 1
        pending = (asked, paths)
        publish()
        startPending()
    }

    private func startPending() {
        guard running < Self.maxLookups, let (number, paths) = pending else { return }
        pending = nil
        running += 1
        let isMissing = isMissing
        Thread {
            let found = paths.map { (Self.key($0.0, $0.1), isMissing($0.0, $0.1)) }
            Task { @MainActor [weak self] in self?.ended(number, found) }
        }.start()
    }

    private func ended(_ number: Int, _ found: [(String, Bool)]) {
        running -= 1
        if number > shown {
            shown = number
            missing = Dictionary(found, uniquingKeysWith: { _, last in last })
            publish()
        }
        startPending()
    }

    private func publish() {
        examples = HelperExamples.examples(apps: apps, installed: installed) { missing[Self.key($0, $1)] ?? false }
    }

    private nonisolated static func key(_ bundle: String, _ relative: String) -> String { bundle + "\u{0}" + relative }
}
