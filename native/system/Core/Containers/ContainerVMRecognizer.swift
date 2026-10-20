/// A Docker-compatible runtime whose VM System recognizes. Podman and other runtimes are out of scope.
public enum ContainerRuntime: String, CaseIterable, Sendable {
    case dockerDesktop
    case orbStack
    case colima

    public var displayName: String {
        switch self {
        case .dockerDesktop: "Docker Desktop"
        case .orbStack: "OrbStack"
        case .colima: "Colima"
        }
    }

    /// The file name of the app bundle every process of the runtime runs from, when it has one.
    var bundleName: String? {
        switch self {
        case .dockerDesktop: "Docker.app"
        case .orbStack: "OrbStack.app"
        case .colima: nil
        }
    }

    /// The runtime a Docker socket belongs to, by its real path: Docker Desktop's `~/.docker/run/docker.sock`,
    /// OrbStack's `~/.orbstack/run/docker.sock`, or `docker.sock` in a Colima profile folder (`~/.colima/<profile>/`,
    /// or `~/.config/colima/<profile>/` where Colima follows XDG).
    public static func owning(socketPath path: String) -> ContainerRuntime? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.suffix(3) == [".docker", "run", "docker.sock"] { return .dockerDesktop }
        if parts.suffix(3) == [".orbstack", "run", "docker.sock"] { return .orbStack }
        let folder = parts.dropLast(2).suffix(2)
        if parts.last == "docker.sock", folder.last == ".colima" || folder == [".config", "colima"] { return .colima }
        return nil
    }
}

/// App rule 3's recognizer. Over one sample it finds the processes of Docker Desktop, OrbStack, and Colima, by a
/// closed rule set; the first that applies places a process:
///
/// 1. The executable is inside an outermost `Docker.app` or `OrbStack.app` bundle: the runtime's own processes.
/// 2. The executable is `limactl` or `colima` (file name or kernel name): Colima's host agent and CLI.
/// 3. A process outside any app bundle with an ancestor placed by rule 1 or 2: what the runtime started, such as
///    `qemu-system-*`, `ssh` port forwarders, and `socket_vmnet` under Lima's host agent.
/// 4. Apple's Virtualization.framework VM service (`com.apple.Virtualization.VirtualMachine`), which launchd starts
///    on behalf of a runtime: the runtime of its responsible process, else the one runtime found among the other
///    members of its coalition. Two runtimes in the coalition leave it unrecognized.
///
/// A responsible PID that belongs to a process started later than the VM service was reused and is ignored.
public struct ContainerVMRecognizer: ContainerVMRecognizing {
    public static let virtualMachineService = "com.apple.Virtualization.VirtualMachine"
    static let colimaExecutables: Set<String> = ["limactl", "colima"]

    public init() {}

    public func containerVMs(in processes: [ProcessFacts]) -> [ContainerVM?] {
        let tree = ProcessTree(processes)
        let bundles = processes.map { $0.executablePath.flatMap(AttributionPass.outermostAppBundle) }
        var found: [ContainerVM?] = processes.indices.map { Self.direct(processes[$0], bundle: bundles[$0]) }

        let runtimeAncestor = tree.nearestAncestor { found[$0] != nil }
        for index in processes.indices where found[index] == nil && bundles[index] == nil {
            guard let ancestor = runtimeAncestor[index], let vm = found[ancestor] else { continue }
            let parent = processes[ancestor]
            found[index] = vm.identified(by: "started by \(parent.name) (pid \(parent.pid))")
        }

        var runtimesByCoalition: [UInt64: [(index: Int, vm: ContainerVM)]] = [:]
        for (index, process) in processes.enumerated() {
            if let coalition = process.coalitionID, let vm = found[index] {
                runtimesByCoalition[coalition, default: []].append((index, vm))
            }
        }
        for (index, process) in processes.enumerated() where found[index] == nil && Self.isVirtualMachineService(process) {
            if let pid = process.responsiblePID, pid != process.pid,
               let responsible = tree.index(of: pid, startedBy: process.identity.startTime), let vm = found[responsible] {
                found[index] = vm.identified(by: "responsible process \(processes[responsible].name) (pid \(pid))")
            } else if let coalition = process.coalitionID, let members = runtimesByCoalition[coalition],
                      Set(members.compactMap(\.vm.runtime)).count == 1, let member = members.first {
                let other = processes[member.index]
                found[index] = member.vm.identified(by: "coalition \(coalition) with \(other.name) (pid \(other.pid))")
            }
        }
        return found
    }

    /// Each running runtime's processes and their macOS usage, ordered as `ContainerRuntime.allCases`.
    public func groups(in processes: [ProcessFacts]) -> [ContainerVMGroup] {
        let found = containerVMs(in: processes)
        return ContainerRuntime.allCases.compactMap { runtime in
            let members = processes.indices.filter { found[$0]?.runtime == runtime }.map { processes[$0] }
            guard !members.isEmpty else { return nil }
            return ContainerVMGroup(runtime: runtime, members: members.map(\.identity), totals: GroupTotals(members))
        }
    }

    /// Rules 1 and 2, from the process alone.
    private static func direct(_ process: ProcessFacts, bundle: String?) -> ContainerVM? {
        if let bundle {
            let name = AttributionPass.lastComponent(bundle)
            guard let runtime = ContainerRuntime.allCases.first(where: { $0.bundleName == name }) else { return nil }
            return ContainerVM(runtime: runtime, detail: "inside \(name)", appBundlePath: bundle)
        }
        let file = process.executablePath.map(AttributionPass.lastComponent)
        if let executable = [file, process.name].compactMap({ $0 }).first(where: colimaExecutables.contains) {
            return ContainerVM(runtime: .colima, detail: "runs \(executable)")
        }
        return nil
    }

    static func isVirtualMachineService(_ process: ProcessFacts) -> Bool {
        process.executablePath.map(AttributionPass.lastComponent) == virtualMachineService
    }
}

/// One running runtime: its processes on this Mac and what macOS measures for them. The containers inside its VM
/// are measured separately, by the runtime (`ContainerReport`); the two are never reconciled.
public struct ContainerVMGroup: Equatable, Sendable {
    public let runtime: ContainerRuntime
    public let members: [ProcessIdentity]
    public let totals: GroupTotals

    public var id: OriginGroupID { OriginGroupID(.containerVM(name: runtime.displayName)) }
}
