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
    /// reached through real folders only, which `subset` takes for an older copy. A link on the way, or a helper that is
    /// there, is checked by `subset` itself (a file inside the app, signed by Subset), which the section does not claim.
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

    /// Whether nothing is at `relative` in `bundle`, each folder before the first absent part being a real folder (not a
    /// link), as `subset` decides an older copy.
    public static func isMissing(_ bundle: String, _ relative: String) -> Bool {
        var path = bundle
        for part in relative.split(separator: "/") {
            path += "/\(part)"
            var status = stat()
            guard lstat(path, &status) == 0 else { return errno == ENOENT }
            guard status.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return false
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
