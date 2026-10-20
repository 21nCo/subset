import Foundation
@testable import SystemCore
import XCTest

/// VM detection fixtures for Docker Desktop, OrbStack, and Colima, the processes the recognizer must leave alone,
/// and rule 3's place in attribution.
final class ContainerVMTests: XCTestCase {
    private let vmService = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
        + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    private let docker = "/Applications/Docker.app"
    private let orbStack = "/Applications/OrbStack.app"
    private let terminal = "/System/Applications/Utilities/Terminal.app"

    // MARK: Fixtures per runtime

    /// Docker Desktop on Apple's Virtualization framework: the UI, the backend, the virtualization helper, and the
    /// VM service launchd starts for it, whose responsible process is the helper.
    private func dockerDesktop() -> [ProcessFacts] {
        [
            fact(700, path: "\(docker)/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop", signature: dockerSignature, coalition: 70, memory: 300),
            fact(701, path: "\(docker)/Contents/MacOS/com.docker.backend", signature: dockerSignature, responsible: 700, coalition: 70, memory: 200),
            fact(702, ppid: 701, path: "\(docker)/Contents/MacOS/com.docker.virtualization", signature: dockerSignature, responsible: 700, coalition: 70, memory: 50),
            fact(703, path: vmService, signature: apple, responsible: 702, coalition: 70, memory: 4_000)
        ]
    }

    /// OrbStack: the app, its helper (which manages the VM), and the VM service.
    private func orbStackRuntime() -> [ProcessFacts] {
        [
            fact(800, path: "\(orbStack)/Contents/MacOS/OrbStack", signature: orbSignature, coalition: 80),
            fact(801, path: "\(orbStack)/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper", signature: orbSignature, responsible: 800, coalition: 80),
            fact(802, path: vmService, signature: apple, responsible: 801, coalition: 80)
        ]
    }

    /// Colima with the `vz` VM type, started with `colima start` in Terminal, which is still running: Lima's host
    /// agent detaches to launchd and runs `ssh` for port forwarding; the VM service's responsible process is
    /// Terminal, and it shares Terminal's coalition with the host agent.
    private func colimaVZ() -> [ProcessFacts] {
        [
            fact(900, path: "\(terminal)/Contents/MacOS/Terminal", signature: apple, coalition: 90),
            fact(901, ppid: 900, path: "/bin/zsh", signature: apple, responsible: 900, coalition: 90),
            fact(902, ppid: 901, path: "/opt/homebrew/Cellar/colima/0.8.1/bin/colima", signature: adHoc, responsible: 900, coalition: 90),
            fact(903, path: "/opt/homebrew/Cellar/lima/1.0.3/bin/limactl", signature: adHoc, responsible: 900, coalition: 90),
            fact(904, ppid: 903, path: "/usr/bin/ssh", signature: apple, responsible: 900, coalition: 90),
            fact(905, path: vmService, signature: apple, responsible: 900, coalition: 90, memory: 2_000)
        ]
    }

    /// Colima with the `qemu` VM type under `brew services`: QEMU is the host agent's child.
    private func colimaQEMU() -> [ProcessFacts] {
        [
            fact(910, path: "/opt/homebrew/Cellar/lima/1.0.3/bin/limactl", signature: adHoc, coalition: 91),
            fact(911, ppid: 910, path: "/opt/homebrew/Cellar/qemu/9.2.0/bin/qemu-system-aarch64", signature: adHoc, coalition: 91)
        ]
    }

    func testDockerDesktopsProcessesAndItsVirtualMachineServiceAreOneRuntime() {
        let vms = ContainerVMRecognizer().containerVMs(in: dockerDesktop())

        XCTAssertEqual(vms.map { $0?.runtime }, Array(repeating: .dockerDesktop, count: 4))
        XCTAssertEqual(vms[0]?.detail, "inside Docker.app")
        XCTAssertEqual(vms[0]?.appBundlePath, docker)
        XCTAssertEqual(vms[3]?.detail, "responsible process com.docker.virtualization (pid 702)")
        XCTAssertEqual(vms[3]?.appBundlePath, docker, "the VM service answers to Docker.app")
        XCTAssertEqual(vms[3]?.name, "Docker Desktop")
    }

    func testOrbStacksVirtualMachineServiceFollowsItsResponsibleHelper() {
        let vms = ContainerVMRecognizer().containerVMs(in: orbStackRuntime())

        XCTAssertEqual(vms.map { $0?.runtime }, [.orbStack, .orbStack, .orbStack])
        XCTAssertEqual(vms[2]?.detail, "responsible process OrbStack Helper (pid 801)")
    }

    func testColimasHostAgentItsChildrenAndItsVirtualMachineServiceAreColima() {
        let vms = ContainerVMRecognizer().containerVMs(in: colimaVZ())

        XCTAssertEqual(vms.map { $0?.runtime }, [nil, nil, nil, .colima, .colima, .colima],
                       "Terminal, its shell, and the colima command are not Colima's VM; the host agent, its ssh, and the VM are")
        XCTAssertEqual(vms[3]?.detail, "runs Lima's host agent (limactl)")
        XCTAssertEqual(vms[4]?.detail, "started by limactl (pid 903)")
        XCTAssertEqual(vms[5]?.detail, "coalition 90 with limactl (pid 903)",
                       "the responsible process is Terminal, so the coalition names the runtime")
        XCTAssertNil(vms[5]?.appBundlePath)
    }

    func testQEMUUnderLimasHostAgentIsColima() {
        let vms = ContainerVMRecognizer().containerVMs(in: colimaQEMU())

        XCTAssertEqual(vms.map { $0?.runtime }, [.colima, .colima])
        XCTAssertEqual(vms[1]?.detail, "started by limactl (pid 910)")
    }

    func testColimaUnderBrewServicesAndAHostAgentWhileItStartsAreColima() {
        let processes = [
            fact(930, path: "/opt/homebrew/opt/colima/bin/colima", signature: adHoc, coalition: 93),
            fact(931, ppid: 930, path: "/opt/homebrew/bin/limactl", signature: adHoc, coalition: 93),
            fact(932, ppid: 931, path: "/opt/homebrew/bin/limactl", signature: adHoc, coalition: 93)
        ]

        let vms = ContainerVMRecognizer().containerVMs(in: processes)

        XCTAssertEqual(vms[0]?.detail, "runs colima under launchd")
        XCTAssertEqual(vms[1]?.detail, "started by colima (pid 930)", "limactl start, under Colima's daemon")
        XCTAssertEqual(vms[2]?.detail, "runs Lima's host agent (limactl)", "the host agent before limactl start exits")
    }

    // MARK: What the recognizer leaves alone

    func testOtherVirtualMachinesAndOutOfScopeRuntimesAreNotRecognized() {
        let utm = "/Applications/UTM.app"
        let processes = [
            // UTM runs its VMs through the same service and its own QEMU.
            fact(1000, path: "\(utm)/Contents/MacOS/UTM", signature: unsigned, coalition: 100),
            fact(1001, path: vmService, signature: apple, responsible: 1000, coalition: 100),
            fact(1002, ppid: 1000, path: "\(utm)/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/qemu-system-aarch64", signature: unsigned, coalition: 100),
            // QEMU run by hand, and Podman's VM, which is excluded.
            fact(1003, path: "/opt/homebrew/bin/qemu-system-x86_64", signature: adHoc, coalition: 101),
            fact(1004, path: "/opt/podman/bin/vfkit", signature: unsigned, coalition: 102),
            // A file merely named like the VM service, outside any runtime's coalition.
            fact(1005, path: "/Users/me/bin/com.apple.Virtualization.VirtualMachine", signature: unsigned, coalition: 103)
        ]

        XCTAssertEqual(ContainerVMRecognizer().containerVMs(in: processes).map { $0?.runtime }, Array(repeating: nil, count: 6))
        XCTAssertEqual(ContainerVMRecognizer().groups(in: processes), [])
    }

    func testAVirtualMachineServiceInACoalitionWithTwoRuntimesIsNotGuessed() {
        let processes = colimaVZ() + [
            fact(920, ppid: 901, path: "\(orbStack)/Contents/MacOS/OrbStack", signature: orbSignature, responsible: 900, coalition: 90)
        ]

        let vms = ContainerVMRecognizer().containerVMs(in: processes)

        XCTAssertNil(vms[5], "Terminal's coalition holds Colima and OrbStack, started from the shell")
        XCTAssertEqual(vms[6]?.runtime, .orbStack)
    }

    func testTheCoalitionNamesNoMoreVirtualMachineServicesThanItsRuntimeRuns() {
        // A tart VM started in the same Terminal: two services, one Lima host agent.
        let tart = colimaVZ() + [fact(906, path: vmService, signature: apple, responsible: 900, coalition: 90)]
        XCTAssertEqual(ContainerVMRecognizer().containerVMs(in: tart).suffix(2).map { $0?.runtime }, [nil, nil])

        // Colima with QEMU in Terminal's coalition, beside a vfkit VM: the host agent runs no VM service.
        let qemu = [
            fact(940, path: "\(terminal)/Contents/MacOS/Terminal", signature: apple, coalition: 94),
            fact(941, path: "/opt/homebrew/bin/limactl", signature: adHoc, responsible: 940, coalition: 94),
            fact(942, ppid: 941, path: "/opt/homebrew/bin/qemu-system-aarch64", signature: adHoc, responsible: 940, coalition: 94),
            fact(943, path: vmService, signature: apple, responsible: 940, coalition: 94)
        ]
        XCTAssertEqual(ContainerVMRecognizer().containerVMs(in: qemu).map { $0?.runtime }, [nil, .colima, .colima, nil])

        // Two Colima profiles, two host agents, two services.
        let profiles = colimaVZ() + [
            fact(907, path: "/opt/homebrew/Cellar/lima/1.0.3/bin/limactl", signature: adHoc, responsible: 900, coalition: 90),
            fact(908, path: vmService, signature: apple, responsible: 900, coalition: 90)
        ]
        XCTAssertEqual(ContainerVMRecognizer().containerVMs(in: profiles).suffix(3).map { $0?.runtime }, [.colima, .colima, .colima])
    }

    func testClientsAndTransientCommandsAreNotTheVM() {
        let system = "/Applications/Subset System.app"
        let processes = colimaVZ() + [
            // docker from /usr/local/bin in the shell, resolved to Docker.app's copy, with a compose plugin and a
            // credential helper; System's own docker child; OrbStack's docker; a transient limactl.
            fact(950, ppid: 901, path: "\(docker)/Contents/Resources/bin/docker", signature: dockerSignature, responsible: 900, coalition: 90),
            fact(951, ppid: 950, path: "\(docker)/Contents/Resources/cli-plugins/compose", signature: dockerSignature, responsible: 900, coalition: 90),
            fact(952, ppid: 950, path: "\(docker)/Contents/Resources/bin/docker-credential-desktop", signature: dockerSignature, responsible: 900, coalition: 90),
            fact(960, path: "\(system)/Contents/MacOS/Subset System", signature: unsigned, coalition: 96),
            fact(961, ppid: 960, path: "\(docker)/Contents/Resources/bin/docker", signature: dockerSignature, responsible: 960, coalition: 96),
            fact(962, ppid: 901, path: "\(orbStack)/Contents/MacOS/xbin/docker", signature: orbSignature, responsible: 900, coalition: 90),
            fact(963, ppid: 901, path: "/opt/homebrew/bin/limactl", signature: adHoc, responsible: 900, coalition: 90)
        ]
        let recognizer = ContainerVMRecognizer()

        XCTAssertEqual(recognizer.containerVMs(in: processes).suffix(7).map { $0?.runtime }, Array(repeating: nil, count: 7))
        let groups = recognizer.groups(in: processes)
        XCTAssertEqual(groups.map(\.runtime), [.colima], "no client creates a Docker Desktop or OrbStack group")
        XCTAssertEqual(groups[0].members.map(\.pid), [903, 904, 905])
        XCTAssertEqual(recognizer.containerVMs(in: processes)[5]?.runtime, .colima, "the clients leave Colima's VM service in place")

        let breakdown = ContainerBreakdown(listing: DockerOutput.listing(""), stats: DockerOutput.stats(""))
        let report = ContainerReport(observedAt: Date(), executable: "/usr/local/bin/docker",
                                     context: DockerContext(name: "colima", host: "unix:///Users/me/.colima/default/docker.sock",
                                                            endpoint: "unix:///Users/me/.colima/default/docker.sock", runtime: .colima),
                                     outcome: .breakdown(breakdown))
        XCTAssertEqual(groups.map { report.status(of: $0.runtime) }, [.measured(breakdown)], "the clients add no runtime to report on")

        let result = Attribution(projectMarkers: FixtureProjectMarkers()).attribute(processes)
        XCTAssertEqual(placement(result, 961).app.group, OriginGroupID(.app(bundlePath: docker)), "a client stays with its app (rule 1)")
        XCTAssertEqual(placement(result, 961).app.rule, .appBundle)
        XCTAssertEqual(placement(result, 963).app.group, OriginGroupID(.terminal), "a transient limactl stays in the terminal")
    }

    func testAShellOrCodingAgentRunUnderARuntimeIsNotTheVM() {
        // Docker Desktop's terminal runs a shell under its UI, and in it a coding agent and its tools; OrbStack's a shell.
        let processes = dockerDesktop() + orbStackRuntime() + [
            fact(720, ppid: 700, path: "/bin/zsh", signature: apple, responsible: 700, coalition: 70),
            fact(721, ppid: 720, path: "/Users/me/.local/bin/claude", signature: unsigned, responsible: 700, coalition: 70),
            fact(722, ppid: 721, path: "/Users/me/.nvm/versions/node/v22.11.0/bin/node", signature: unsigned, responsible: 700, coalition: 70),
            fact(820, ppid: 800, path: "/bin/zsh", signature: apple, responsible: 800, coalition: 80),
            fact(821, ppid: 820, path: "/Users/me/.cargo/bin/cargo", signature: unsigned, responsible: 800, coalition: 80)
        ]
        let recognizer = ContainerVMRecognizer()

        XCTAssertEqual(recognizer.containerVMs(in: processes).suffix(5).map { $0?.runtime }, Array(repeating: nil, count: 5))
        XCTAssertEqual(recognizer.groups(in: processes).map { $0.members.map(\.pid) }, [[700, 701, 702, 703], [800, 801, 802]])

        let result = Attribution(projectMarkers: FixtureProjectMarkers()).attribute(processes)
        for pid: Int32 in [721, 722] {
            XCTAssertEqual(placement(result, pid).app.group, OriginGroupID(.agent(name: "claude")), "pid \(pid)")
            XCTAssertEqual(placement(result, pid).app.rule, .codingAgent, "pid \(pid)")
        }
        for pid: Int32 in [720, 820, 821] {
            XCTAssertNotEqual(placement(result, pid).app.rule, .containerVM, "pid \(pid)")
        }
    }

    func testAReusedResponsiblePIDDoesNotNameTheRuntime() {
        // The VM service's responsible PID now belongs to a Docker.app process that started after it.
        let processes = [
            fact(1100, start: 50, path: "\(docker)/Contents/MacOS/com.docker.backend", signature: dockerSignature, coalition: 110),
            fact(1101, start: 20, path: vmService, signature: apple, responsible: 1100, coalition: 111)
        ]

        XCTAssertNil(ContainerVMRecognizer().containerVMs(in: processes)[1])
    }

    func testAnotherAppStartedUnderARuntimeKeepsItsOwnBundle() {
        let processes = colimaQEMU() + [
            fact(912, ppid: 910, path: "/Applications/Other.app/Contents/MacOS/Other", signature: unsigned, coalition: 91)
        ]

        XCTAssertNil(ContainerVMRecognizer().containerVMs(in: processes)[2])
    }

    // MARK: Groups and attribution

    func testEachRunningRuntimeIsOneGroupWithItsMacOSUsage() {
        let groups = ContainerVMRecognizer().groups(in: dockerDesktop() + colimaQEMU() + [fact(1, path: "/sbin/launchd", signature: apple)])

        XCTAssertEqual(groups.map(\.runtime), [.dockerDesktop, .colima])
        XCTAssertEqual(groups[0].members.map(\.pid), [700, 701, 702, 703])
        XCTAssertEqual(groups[0].totals.memory.sum, 4_550)
        XCTAssertEqual(groups[0].totals.processCount, 4)
        XCTAssertEqual(groups[0].id, OriginGroupID(.containerVM(name: "Docker Desktop")))
        XCTAssertEqual(groups[1].totals.memory.sum, nil, "Colima's processes were not measured")
        XCTAssertEqual(groups[1].totals.memory.unmeasuredCount, 2)
    }

    func testRule3PlacesARuntimesProcessesBeforeTheAppBundleAndMacOSRules() {
        let result = Attribution(projectMarkers: FixtureProjectMarkers()).attribute(dockerDesktop() + colimaVZ())
        let vm = OriginGroupID(.containerVM(name: "Docker Desktop"))

        for pid: Int32 in [700, 701, 702, 703] {
            let app = placement(result, pid).app
            XCTAssertEqual(app.group, vm, "pid \(pid)")
            XCTAssertEqual(app.rule, .containerVM)
            XCTAssertEqual(app.confidence, .rule)
            XCTAssertEqual(app.conflicts, [], "Docker.app and its Team ID agree with the Docker Desktop VM (pid \(pid))")
        }
        XCTAssertEqual(placement(result, 703).app.evidence,
                       [.containerVM(ContainerVM(runtime: .dockerDesktop, detail: "responsible process com.docker.virtualization (pid 702)",
                                                 appBundlePath: docker))])
        XCTAssertEqual(result.app.first { $0.id == vm }?.name, "Docker Desktop")
        XCTAssertEqual(result.app.first { $0.id == vm }?.totals.memory.sum, 4_550)

        let colima = OriginGroupID(.containerVM(name: "Colima"))
        XCTAssertEqual(placement(result, 905).app.group, colima, "the VM service under /System is not macOS")
        XCTAssertEqual(placement(result, 904).app.group, colima, "nor is /usr/bin/ssh under the host agent")
        XCTAssertEqual(Set(placement(result, 904).app.conflicts.map(\.group)), [OriginGroupID(.app(bundlePath: terminal))],
                       "the responsible Terminal and its coalition name another app and are recorded")
        XCTAssertEqual(placement(result, 901).app.group, OriginGroupID(.terminal), "the shell stays in the terminal")
        XCTAssertEqual(placement(result, 900).app.group, OriginGroupID(.app(bundlePath: terminal)))
    }

    func testWithoutARecognizerTheVirtualMachineServiceIsMacOS() {
        let result = Attribution(projectMarkers: FixtureProjectMarkers(), containerVM: nil).attribute(dockerDesktop())

        XCTAssertEqual(placement(result, 703).app.group, OriginGroupID(.macOS))
        XCTAssertEqual(placement(result, 701).app.group, OriginGroupID(.app(bundlePath: docker)))
    }

    func testDockerSocketsNameTheirRuntime() {
        XCTAssertEqual(ContainerRuntime.owning(socketPath: "/Users/me/.docker/run/docker.sock"), .dockerDesktop)
        let desktopData = "/Users/me/Library/Containers/com.docker.docker/Data/"
        XCTAssertEqual(ContainerRuntime.owning(socketPath: desktopData + "docker-cli.sock"), .dockerDesktop, "what ~/.docker/run/docker.sock links to")
        XCTAssertEqual(ContainerRuntime.owning(socketPath: desktopData + "docker.raw.sock"), .dockerDesktop)
        XCTAssertNil(ContainerRuntime.owning(socketPath: desktopData + "backend.sock"))
        XCTAssertEqual(ContainerRuntime.owning(socketPath: "/Users/me/.orbstack/run/docker.sock"), .orbStack)
        XCTAssertEqual(ContainerRuntime.owning(socketPath: "/Users/me/.colima/default/docker.sock"), .colima)
        XCTAssertEqual(ContainerRuntime.owning(socketPath: "/Users/me/.config/colima/work/docker.sock"), .colima)
        XCTAssertNil(ContainerRuntime.owning(socketPath: "/var/run/docker.sock"))
        XCTAssertNil(ContainerRuntime.owning(socketPath: "/Users/colima/sockets/docker.sock"), "a user named colima is not Colima")
        XCTAssertNil(ContainerRuntime.owning(socketPath: "/Users/me/.colima/default/containerd.sock"))
        XCTAssertNil(ContainerRuntime.owning(socketPath: "/Users/me/.local/share/containers/podman/machine/podman.sock"), "Podman is out of scope")
        XCTAssertNil(ContainerRuntime.owning(socketPath: "/Users/me/.ssh/forwarded/docker.sock"), "a socket forwarded from another machine")
    }

    // MARK: Helpers

    private var apple: CodeSignature { CodeSignature(signingID: "com.apple.x", teamID: nil, isPlatformBinary: true) }
    private var adHoc: CodeSignature { CodeSignature(signingID: "limactl", teamID: nil, isPlatformBinary: false) }
    private var unsigned: CodeSignature { CodeSignature(signingID: nil, teamID: nil, isPlatformBinary: false) }
    private var dockerSignature: CodeSignature { CodeSignature(signingID: "com.docker.docker", teamID: "9BNSXJN65R", isPlatformBinary: false) }
    private var orbSignature: CodeSignature { CodeSignature(signingID: "dev.kdrag0n.MacVirt", teamID: "HUAQ24HBR6", isPlatformBinary: false) }

    private func placement(_ result: AttributionResult, _ pid: Int32) -> ProcessAttribution {
        result.processes.first { $0.identity.pid == pid } ?? result.processes[0]
    }

    /// A recorded process. A parent of 1 is launchd; responsibility defaults to the process itself.
    private func fact(_ pid: Int32, start: UInt64 = 10, ppid: Int32 = 1, path: String, signature: CodeSignature,
                      responsible: Int32? = nil, coalition: UInt64? = nil, memory: UInt64? = nil) -> ProcessFacts {
        let usage: UsageReading = memory.map {
            .available(RawProcessUsage(physFootprint: $0, userTime: 0, systemTime: 0, energy: 0, billedEnergy: 0))
        } ?? .unavailable
        let record = RawProcessRecord(identity: ProcessIdentity(pid: pid, startTime: start), ppid: ppid, uid: 501,
                                      executablePath: path, name: (path as NSString).lastPathComponent, usage: usage)
        var facts = ProcessFacts(record: record, timebase: MachTimebase(numer: 1, denom: 1))
        facts.origin = OriginSignals(
            responsibleProcess: .value(responsible ?? pid, source: .responsibility),
            coalition: .value(coalition ?? UInt64(pid) + 100_000, source: .coalitionInfo),
            codeSignature: .value(signature, source: .codeSigning),
            launchdJobs: .value(LaunchdJobs(jobs: []), source: .launchdPlists),
            workingDirectory: .unavailable(.denied, source: .vnodePathInfo),
            terminal: .value(ControllingTerminal.none, source: .bsdInfo)
        )
        return facts
    }
}
