import Foundation
import SystemCore

/// Plain-language text for why a process is in its group: the rule, its confidence, and each piece of evidence.
public struct OriginExplanation: Sendable {
    let format: UsageFormat
    /// The name of the sampled process with this PID, for evidence that names another process.
    let processName: @Sendable (Int32) -> String?
    /// The process being explained, so "Runs claude" can be told from "Child of claude".
    let process: ProcessFacts
    /// How a path is shown: with `~` for the home folder, or as Explain sends it (`ExplainRedactor.path`).
    let showPath: @Sendable (String) -> String

    public init(process: ProcessFacts, format: UsageFormat, path: (@Sendable (String) -> String)? = nil,
                processName: @escaping @Sendable (Int32) -> String?) {
        self.process = process
        self.format = format
        showPath = path ?? { [format] in format.path($0) }
        self.processName = processName
    }

    public static func rule(_ rule: AppRule) -> String {
        switch rule {
        case .appBundle: "Inside an app bundle"
        case .macOS: "Apple binary in a system location"
        case .containerVM: "Part of a container VM"
        case .codingAgent: "Coding agent session"
        case .terminalSession: "Terminal session"
        case .responsibleProcess: "Responsible app"
        case .launchdJob: "launchd job"
        case .homebrew: "Installed by Homebrew"
        case .signingTeam: "Signing team"
        case .unattributed: "No origin found; grouped by executable"
        }
    }

    public static func rule(_ rule: VendorRule) -> String {
        switch rule {
        case .platformBinary: "Apple platform binary"
        case .teamID: "Team ID in the code signature"
        case .unsigned: "Unsigned or ad hoc signed"
        case .signatureUnavailable: "Signature unavailable"
        }
    }

    public static func rule(_ rule: LaunchSourceRule) -> String {
        switch rule {
        case .codingAgent: "Started by a coding agent"
        case .terminalSession: "Started in a terminal"
        case .launchdJob: "launchd job"
        case .loginItem: "Login item"
        case .appLaunched: "Started by an app"
        case .startedByLaunchd: "Started by launchd"
        case .parentNotSampled: "Parent not in the sample"
        }
    }

    public static func rule(_ rule: ProjectRule) -> String {
        switch rule {
        case .marker: "Project marker found"
        case .workingDirectory: "Working directory"
        case .none: "Working directory unavailable"
        }
    }

    public static func confidence(_ confidence: AttributionConfidence) -> String {
        switch confidence {
        case .rule: "Rule"
        case .signal: "Signal"
        case .fallback: "Fallback"
        }
    }

    /// What the confidence badge means, for its help text and accessibility value.
    public static func confidenceMeaning(_ confidence: AttributionConfidence) -> String {
        switch confidence {
        case .rule: "A fixed rule over the executable path, the parent chain, or names placed it."
        case .signal: "A signal macOS reported placed it: the responsible process, coalition, launchd job, or signature."
        case .fallback: "Nothing identified an origin, so it is grouped by what is known about it."
        }
    }

    public func describe(_ evidence: AttributionEvidence) -> String {
        switch evidence {
        case let .executable(path, name):
            return path.map { "Runs `\(showPath($0))`" } ?? "No executable path; named \(OriginGroup.displayName(name))"
        case let .appBundle(path):
            return "Inside `\(bundleName(path))`"
        case let .systemLocation(prefix, platformBinary):
            switch platformBinary {
            case true?: return "Apple platform binary under \(prefix)"
            case false?: return "Under \(prefix), but not an Apple platform binary"
            case nil: return "Under \(prefix) on the sealed system volume; signature not read"
            }
        case let .containerVM(vm):
            return "Part of \(vm.name)'s VM: \(vm.detail)"
        case let .codingAgent(name, pid):
            let base = pid == process.pid ? "Runs \(name)" : "Child of \(name) (pid \(pid))"
            return base + workingDirectorySuffix
        case let .terminalApp(name, pid, _):
            return "Started in \(name) (pid \(pid))" + workingDirectorySuffix
        case let .controllingTerminal(device):
            return "Has controlling terminal \(device)"
        case let .responsibleProcess(pid, bundlePath):
            return "macOS holds `\(bundleName(bundlePath))` responsible (\(processLabel(pid)))"
        case let .coalitionLeader(coalition, pid, bundlePath):
            return "Coalition \(coalition) is led by `\(bundleName(bundlePath))` (\(processLabel(pid)))"
        case let .launchdJob(job):
            return "launchd job `\(job.label)` in \(showPath(job.plistPath))"
        case let .orphanedLaunchdJob(job):
            return "Orphaned launchd plist `\(job.label)` in \(showPath(job.plistPath)); its program no longer exists"
        case let .homebrew(formula):
            return formula.map { "Homebrew formula \($0)" } ?? "Under a Homebrew prefix"
        case let .signature(signature):
            return describe(signature)
        case let .signatureUnavailable(failure):
            return failure.map { "Signature unavailable: \($0.reason)" } ?? "Signature not read yet"
        case let .loginItem(bundlePath):
            return "Login item inside `\(bundleName(bundlePath))`"
        case .parentIsLaunchd:
            return "Started by launchd"
        case let .inheritedFrom(pid):
            return "Inherits its launch source from \(processLabel(pid))"
        case let .parentNotSampled(ppid):
            return "Parent pid \(ppid) is not in the sample"
        case let .workingDirectory(path):
            return "Working directory \(showPath(path))"
        case let .workingDirectoryUnavailable(failure):
            return failure.map { "Working directory unavailable: \($0.reason)" } ?? "Working directory not read yet"
        case let .projectMarker(directory, marker):
            return "`\(marker)` in \(showPath(directory))"
        case let .projectMarkersSkipped(volume):
            return "Project markers not looked for on the network volume at \(volume)"
        }
    }

    /// A conflict: another rule that also matched, the group it names, and its evidence.
    public func describe(_ conflict: AttributionConflict, groupName: String) -> String {
        let evidence = conflict.evidence.map(describe).joined(separator: "; ")
        return "\(Self.rule(conflict.rule)) also points to \(groupName)" + (evidence.isEmpty ? "" : ": \(evidence)")
    }

    private func describe(_ signature: CodeSignature) -> String {
        if signature.isPlatformBinary { return "Signed by Apple as part of macOS" }
        guard let signingID = signature.signingID else { return "Unsigned" }
        guard let teamID = signature.teamID else { return "Ad hoc signed as \(signingID), no Team ID" }
        return "Signed by \(signature.teamName.map { "\($0) (\(teamID))" } ?? "team \(teamID)") as \(signingID)"
    }

    private var workingDirectorySuffix: String {
        process.workingDirectory.map { " in \(showPath($0))" } ?? ""
    }

    private func processLabel(_ pid: Int32) -> String {
        processName(pid).map { "\($0), pid \(pid)" } ?? "pid \(pid)"
    }

    /// The bundle's name as its path is shown, so a redacted path's bundle is not named.
    private func bundleName(_ path: String) -> String {
        let shown = showPath(path)
        return shown.split(separator: "/").last.map(String.init) ?? shown
    }
}
