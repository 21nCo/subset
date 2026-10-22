import Foundation

/// One piece of evidence for an item, as sent: what it is, from a closed list, and the path, name, or identifier it
/// names, each a value of its own. It holds no message or other free text: why a signal is unavailable is a closed
/// category (`ExplainFailure`).
public struct ExplainEvidence: Encodable, Equatable, Sendable {
    public let kind: Kind
    public let path: ExplainPath?
    /// A process, app, VM, coding agent, terminal, Homebrew formula, signing team, project marker, or reclaim rule name.
    public let name: String?
    /// A launchd label, Team ID, signing identifier, or terminal device.
    public let identifier: String?
    public let failure: ExplainFailure?

    init(kind: Kind, path: ExplainPath?, name: String?, identifier: String?, failure: ExplainFailure?) {
        self.kind = kind
        self.path = path
        self.name = name
        self.identifier = identifier
        self.failure = failure
    }

    public enum Kind: String, Encodable, CaseIterable, Sendable {
        case executable, noExecutablePath, appBundle
        case appleBinaryInSystemLocation, notAppleBinaryInSystemLocation, sealedSystemVolumeSignatureNotRead
        case containerVM, runsCodingAgent, startedByCodingAgent, startedInTerminal, controllingTerminal
        case responsibleApp, coalitionLeader, launchdJob, orphanedLaunchdJob, homebrew
        case signedByApple, signedByTeam, adHocSigned, unsigned, signatureUnavailable, signatureNotRead
        case loginItem, startedByLaunchd, inheritsLaunchSource, parentNotSampled
        case workingDirectory, workingDirectoryUnavailable, workingDirectoryNotRead
        case projectMarker, projectMarkersSkipped
        case reclaimRule

        public var title: String {
            switch self {
            case .executable: "Runs the executable"
            case .noExecutablePath: "Has no executable path; named"
            case .appBundle: "Inside the app bundle"
            case .appleBinaryInSystemLocation: "Apple platform binary in the system location"
            case .notAppleBinaryInSystemLocation: "In the system location, but not an Apple platform binary"
            case .sealedSystemVolumeSignatureNotRead: "On the sealed system volume, signature not read"
            case .containerVM: "Part of the container VM"
            case .runsCodingAgent: "Runs the coding agent, in its working directory"
            case .startedByCodingAgent: "Started by the coding agent, in its working directory"
            case .startedInTerminal: "Started in the terminal app, in its working directory"
            case .controllingTerminal: "Has the controlling terminal"
            case .responsibleApp: "macOS holds this process and app bundle responsible"
            case .coalitionLeader: "Its coalition is led by this process and app bundle"
            case .launchdJob: "launchd job and its plist"
            case .orphanedLaunchdJob: "launchd job and its plist, whose program no longer exists"
            case .homebrew: "Installed by Homebrew"
            case .signedByApple: "Signed by Apple as part of macOS"
            case .signedByTeam: "Signed by the developer team"
            case .adHocSigned: "Ad hoc signed, with no Team ID, as"
            case .unsigned: "Unsigned"
            case .signatureUnavailable: "Signature unavailable"
            case .signatureNotRead: "Signature not read yet"
            case .loginItem: "Login item inside the app bundle"
            case .startedByLaunchd: "Started by launchd"
            case .inheritsLaunchSource: "Inherits its launch source from the process"
            case .parentNotSampled: "Its parent is not in the sample"
            case .workingDirectory: "Working directory"
            case .workingDirectoryUnavailable: "Working directory unavailable"
            case .workingDirectoryNotRead: "Working directory not read yet"
            case .projectMarker: "Project marker in the folder"
            case .projectMarkersSkipped: "Project markers not looked for on the network volume"
            case .reclaimRule: "Matches the reclaim rule"
            }
        }
    }

    /// The evidence as a line of the prompt: its kind, then the values it names.
    var line: String {
        let values = [name, identifier, path?.value, failure?.title].compactMap { $0 }
        return kind.title + (values.isEmpty ? "" : ": " + values.joined(separator: ", "))
    }
}

/// Why a signal could not be read, as sent: a category, never the error's text or the paths it names.
public enum ExplainFailure: String, Encodable, CaseIterable, Sendable {
    case denied, processExited, systemError, securityError, noExecutablePath, unexpectedResult, unsupportedMacOS
    case launchdPlistsNotAllRead

    public init(_ failure: SignalFailure) {
        self = switch failure {
        case .symbolMissing: .unsupportedMacOS
        case .denied: .denied
        case .processExited: .processExited
        case .systemError: .systemError
        case .securityError: .securityError
        case .noExecutablePath: .noExecutablePath
        case .unexpectedResult: .unexpectedResult
        case .incompleteScan: .launchdPlistsNotAllRead
        }
    }

    public var title: String {
        switch self {
        case .denied: "macOS denied the read"
        case .processExited: "the process exited while it was read"
        case .systemError: "a system call failed"
        case .securityError: "the Security framework failed"
        case .noExecutablePath: "the process has no executable path"
        case .unexpectedResult: "macOS returned a result System cannot use"
        case .unsupportedMacOS: "this macOS does not offer the call"
        case .launchdPlistsNotAllRead: "no readable launchd plist names it, but not every plist could be read"
        }
    }
}

/// Why a suggestion's space was not measured, as sent: a category, never the reason's text, a tool's message, or the
/// paths they name.
public enum ExplainNotMeasured: String, Encodable, CaseIterable, Sendable {
    /// An item the rule needs could not be read, or a folder could not be searched in full.
    case notRead
    case dockerNotFound, dockerNotRunning, dockerContextNotOnThisMac, dockerFailed, dockerStopped, dockerNotReported

    /// Why Docker's image space was not measured; `nil` when it was not asked.
    public init(docker reason: ContainerUnavailable?) {
        self = switch reason {
        case .cliNotFound?: .dockerNotFound
        case .daemonNotRunning?: .dockerNotRunning
        case .contextUnreadable?, .remoteContext?, .contextNotRecognized?: .dockerContextNotOnThisMac
        case .timedOut?, .failed?, .launchFailed?, .outputTooLarge?, .unparsableOutput?: .dockerFailed
        case .cancelled?: .dockerStopped
        case nil: .dockerNotReported
        }
    }

    public var title: String {
        switch self {
        case .notRead: "an item or folder the rule needs could not be read"
        case .dockerNotFound: "no docker command was found"
        case .dockerNotRunning: "the Docker daemon is not running"
        case .dockerContextNotOnThisMac: "the current Docker context is not a VM on this Mac System recognizes"
        case .dockerFailed: "docker system df failed"
        case .dockerStopped: "docker system df was stopped before it finished"
        case .dockerNotReported: "docker system df did not report reclaimable image space"
        }
    }
}

extension ExplainFacts.Evidence {
    /// A process's attribution evidence as sent: its paths, names, and identifiers as values, an unavailable signal's
    /// reason as a category. `processName` names another sampled process by its PID.
    public init(_ evidence: AttributionEvidence, of process: ProcessFacts, processName: (Int32) -> String?) {
        switch evidence {
        case let .executable(path, name):
            self = path.map { Self(.executable, path: $0) } ?? Self(.noExecutablePath, name: name)
        case let .appBundle(path):
            self = Self(.appBundle, path: path)
        case let .systemLocation(prefix, platformBinary):
            let kind: ExplainEvidence.Kind = switch platformBinary {
            case true?: .appleBinaryInSystemLocation
            case false?: .notAppleBinaryInSystemLocation
            case nil: .sealedSystemVolumeSignatureNotRead
            }
            self = Self(kind, path: prefix)
        case let .containerVM(vm):
            self = Self(.containerVM, name: vm.name)
        case let .codingAgent(name, pid):
            self = Self(pid == process.pid ? .runsCodingAgent : .startedByCodingAgent, path: process.workingDirectory, name: name)
        case let .terminalApp(name, _, _):
            self = Self(.startedInTerminal, path: process.workingDirectory, name: name)
        case let .controllingTerminal(device):
            self = Self(.controllingTerminal, identifier: device)
        case let .responsibleProcess(pid, bundlePath):
            self = Self(.responsibleApp, path: bundlePath, name: processName(pid))
        case let .coalitionLeader(_, pid, bundlePath):
            self = Self(.coalitionLeader, path: bundlePath, name: processName(pid))
        case let .launchdJob(job):
            self = Self(.launchdJob, path: job.plistPath, identifier: job.label)
        case let .orphanedLaunchdJob(job):
            self = Self(.orphanedLaunchdJob, path: job.plistPath, identifier: job.label)
        case let .homebrew(formula):
            self = Self(.homebrew, name: formula)
        case let .signature(signature):
            if signature.isPlatformBinary {
                self = Self(.signedByApple)
            } else if let teamID = signature.teamID {
                self = Self(.signedByTeam, name: signature.teamName, identifier: teamID)
            } else if let signingID = signature.signingID {
                self = Self(.adHocSigned, identifier: signingID)
            } else {
                self = Self(.unsigned)
            }
        case let .signatureUnavailable(failure):
            self = failure.map { Self(.signatureUnavailable, failure: ExplainFailure($0)) } ?? Self(.signatureNotRead)
        case let .loginItem(bundlePath):
            self = Self(.loginItem, path: bundlePath)
        case .parentIsLaunchd:
            self = Self(.startedByLaunchd)
        case let .inheritedFrom(pid):
            self = Self(.inheritsLaunchSource, name: processName(pid))
        case .parentNotSampled:
            self = Self(.parentNotSampled)
        case let .workingDirectory(path):
            self = Self(.workingDirectory, path: path)
        case let .workingDirectoryUnavailable(failure):
            self = failure.map { Self(.workingDirectoryUnavailable, failure: ExplainFailure($0)) } ?? Self(.workingDirectoryNotRead)
        case let .projectMarker(directory, marker):
            self = Self(.projectMarker, path: directory, name: marker)
        case let .projectMarkersSkipped(volume):
            self = Self(.projectMarkersSkipped, path: volume)
        }
    }
}
