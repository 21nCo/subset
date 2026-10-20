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

    /// The runtime a Docker socket belongs to, by its real path: Docker Desktop's `~/.docker/run/docker.sock` or the
    /// sockets in its app container that it links to (`docker-cli.sock`, `docker.raw.sock`), OrbStack's
    /// `~/.orbstack/run/docker.sock`, or `docker.sock` in a Colima profile folder (`~/.colima/<profile>/`, or
    /// `~/.config/colima/<profile>/` where Colima follows XDG). Any other socket, such as Podman's or one forwarded
    /// from another machine, belongs to none.
    public static func owning(socketPath path: String) -> ContainerRuntime? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.suffix(3) == [".docker", "run", "docker.sock"] { return .dockerDesktop }
        if parts.dropLast().suffix(4) == ["Library", "Containers", "com.docker.docker", "Data"],
           parts.last == "docker-cli.sock" || parts.last == "docker.raw.sock" { return .dockerDesktop }
        if parts.suffix(3) == [".orbstack", "run", "docker.sock"] { return .orbStack }
        let folder = parts.dropLast(2).suffix(2)
        if parts.last == "docker.sock", folder.last == ".colima" || folder == [".config", "colima"] { return .colima }
        return nil
    }
}

/// App rule 3's recognizer. Over one sample it finds the processes that run Docker Desktop's, OrbStack's, and
/// Colima's VM and daemon, by a closed rule set; the first that applies places a process:
///
/// 1. The executable is inside an outermost `Docker.app` or `OrbStack.app` bundle and is not one of its clients
///    (`isClient`): the runtime's own processes.
/// 2. Lima's host agent, `limactl` whose parent is launchd or another `limactl`, or Colima's daemon, `colima` whose
///    parent is launchd (`brew services`, `colima daemon`), by file name or kernel name. A `limactl` or `colima`
///    command run from a shell, or by such a command (`colima start` running `limactl`), is transient, not the VM;
///    one that Colima's daemon or the host agent runs is the runtime's by rule 3.
/// 3. A process outside any app bundle with an ancestor placed by rule 1 or 2: what the runtime started, such as
///    `qemu-system-*`, `ssh` port forwarders, and `socket_vmnet` under Lima's host agent. A shell, a coding agent,
///    or a client between them (`isBoundary`), such as Docker Desktop's terminal, ends it: neither it nor what runs
///    in it is the VM.
/// 4. Apple's Virtualization.framework VM service (`com.apple.Virtualization.VirtualMachine`), which launchd starts
///    on behalf of a runtime: the runtime of its responsible process, else the one runtime found among the other
///    members of its coalition, when that runtime accounts for every such service there (`vmCapacity`). Two
///    runtimes in the coalition, or more services than the runtime runs VMs, leave them unrecognized.
///
/// A client (the `docker` CLI and its plugins and credential helpers, `kubectl`, OrbStack's `orb`) and a transient
/// `limactl` or `colima` command are never the VM: they create no group, start no poll, and are placed by the later
/// App rules, so a client inside an app bundle stays with that app (rule 1). A responsible PID that belongs to a
/// process started later than the VM service was reused and is ignored.
public struct ContainerVMRecognizer: ContainerVMRecognizing {
    public static let virtualMachineService = "com.apple.Virtualization.VirtualMachine"
    static let clientExecutables: Set<String> = ["docker", "kubectl", "hub-tool", "com.docker.cli", "orb", "orbctl"]
    static let clientPrefixes = ["docker-", "kubectl-"]
    static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish", "tcsh", "csh", "ksh", "nu"]

    public init() {}

    public func containerVMs(in processes: [ProcessFacts]) -> [ContainerVM?] {
        let tree = ProcessTree(processes)
        let bundles = processes.map { $0.executablePath.flatMap(AttributionPass.outermostAppBundle) }
        let commands = processes.map(Self.colimaCommand)
        let hostAgents = Set(processes.indices.filter { index in
            commands[index] == "limactl" && (processes[index].ppid == 1 || tree.parent[index].map { commands[$0] == "limactl" } == true)
        })
        var found: [ContainerVM?] = processes.indices.map { index in
            if let bundle = bundles[index] { return Self.bundled(processes[index], bundle: bundle) }
            if hostAgents.contains(index) { return ContainerVM(runtime: .colima, detail: "runs Lima's host agent (limactl)") }
            if commands[index] == "colima", processes[index].ppid == 1 { return ContainerVM(runtime: .colima, detail: "runs colima under launchd") }
            return nil
        }

        let boundaries = processes.map(Self.isBoundary)
        let runtimeAncestor = tree.nearestAncestor { found[$0] != nil || boundaries[$0] }
        for index in processes.indices where found[index] == nil && bundles[index] == nil && !boundaries[index] {
            guard let ancestor = runtimeAncestor[index], let vm = found[ancestor] else { continue }
            let parent = processes[ancestor]
            found[index] = vm.identified(by: "started by \(parent.name) (pid \(parent.pid))")
        }
        // Host agents that run QEMU, whose VM is not a Virtualization.framework service.
        let qemuAgents = Set(processes.indices.compactMap { index in
            Self.isQEMU(processes[index]) ? runtimeAncestor[index].flatMap { hostAgents.contains($0) ? $0 : nil } : nil
        })

        var leftByCoalition: [UInt64: [Int]] = [:]
        for (index, process) in processes.enumerated() where found[index] == nil && Self.isVirtualMachineService(process) {
            if let pid = process.responsiblePID, pid != process.pid,
               let responsible = tree.index(of: pid, startedBy: process.identity.startTime), let vm = found[responsible] {
                found[index] = vm.identified(by: "responsible process \(processes[responsible].name) (pid \(pid))")
            } else if let coalition = process.coalitionID {
                leftByCoalition[coalition, default: []].append(index)
            }
        }
        var runtimesByCoalition: [UInt64: [(index: Int, vm: ContainerVM)]] = [:]
        for (index, process) in processes.enumerated() {
            if let coalition = process.coalitionID, let vm = found[index] {
                runtimesByCoalition[coalition, default: []].append((index, vm))
            }
        }
        for (coalition, services) in leftByCoalition {
            guard let members = runtimesByCoalition[coalition], Set(members.compactMap(\.vm.runtime)).count == 1,
                  let member = members.first(where: { !Self.isVirtualMachineService(processes[$0.index]) }),
                  let runtime = member.vm.runtime else { continue }
            let capacity = Self.vmCapacity(of: runtime, members: members.map(\.index), hostAgents: hostAgents, qemuAgents: qemuAgents)
            // Services already placed through their responsible process use up part of it.
            let placed = members.count { Self.isVirtualMachineService(processes[$0.index]) }
            guard services.count <= capacity - placed else { continue }
            let other = processes[member.index]
            for index in services {
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

    /// Rule 1, for a process inside an app bundle.
    private static func bundled(_ process: ProcessFacts, bundle: String) -> ContainerVM? {
        let name = AttributionPass.lastComponent(bundle)
        guard let runtime = ContainerRuntime.allCases.first(where: { $0.bundleName == name }),
              let path = process.executablePath, !isClient(path: path, bundle: bundle) else { return nil }
        return ContainerVM(runtime: runtime, detail: "inside \(name)", appBundlePath: bundle)
    }

    /// A command-line client the runtime's app ships (`Docker.app/Contents/Resources/bin/docker`, the target of
    /// `/usr/local/bin/docker`; OrbStack's `xbin/docker`, the target of `~/.orbstack/bin/docker`), by file name or
    /// a `cli-plugins` folder. It talks to the daemon and is no part of the VM.
    static func isClient(path: String, bundle: String) -> Bool {
        let file = AttributionPass.lastComponent(path)
        return clientExecutables.contains(file) || clientPrefixes.contains(where: file.hasPrefix)
            || path.dropFirst(bundle.count).split(separator: "/").contains("cli-plugins")
    }

    /// Where rule 3 stops: a shell, a coding agent, or a client, by file name or kernel name. What runs there is the
    /// user's, even under a runtime's process.
    static func isBoundary(_ process: ProcessFacts) -> Bool {
        if AttributionPass.agentName(process) != nil { return true }
        return [process.executablePath.map(AttributionPass.lastComponent), process.name].contains { name in
            guard let name else { return false }
            return shells.contains(name) || clientExecutables.contains(name) || clientPrefixes.contains(where: name.hasPrefix)
        }
    }

    /// `limactl` or `colima`, by file name or kernel name.
    private static func colimaCommand(_ process: ProcessFacts) -> String? {
        [process.executablePath.map(AttributionPass.lastComponent), process.name].compactMap { $0 }
            .first { $0 == "limactl" || $0 == "colima" }
    }

    /// How many Virtualization.framework VMs a runtime's processes in one coalition run: one for an app's runtime,
    /// and one per Lima host agent that does not run QEMU for Colima.
    private static func vmCapacity(of runtime: ContainerRuntime, members: [Int], hostAgents: Set<Int>, qemuAgents: Set<Int>) -> Int {
        guard runtime == .colima else { return 1 }
        return members.filter { hostAgents.contains($0) && !qemuAgents.contains($0) }.count
    }

    private static func isQEMU(_ process: ProcessFacts) -> Bool {
        [process.executablePath.map(AttributionPass.lastComponent), process.name].contains { $0?.hasPrefix("qemu-system-") == true }
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
