import Foundation
import SystemCore

/// Two process samples, the second attributed to origins, and the memory state read with it.
public struct ProcessMeasurement: Sendable {
    /// The second sample, or why sampling failed.
    public let snapshot: Result<ProcessSnapshot, ProcessSourceFailure>
    /// The second sample's processes with their origin signals, attributed. `nil` when sampling failed.
    public let processes: [ProcessFacts]
    public let attribution: AttributionResult?
    /// The processes the first sample listed: of those without CPU in the second, only these had a failed read.
    public let firstSample: Set<ProcessIdentity>
    public let memory: SystemMemory
    /// When the second sample was read.
    public let observedAt: Date
}

/// Why listing processes failed, as text.
public struct ProcessSourceFailure: Error, Sendable {
    public let message: String
}

/// Reads this Mac's processes twice, `interval` apart, then their origin signals and attribution. Only reads.
public struct ProcessProbe: Sendable {
    public var source: any ProcessSource
    public var hostCPU: any HostCPUSource
    public var memory: any SystemMemorySource
    public var origin: OriginSignalReader?
    public var attribution: Attribution
    public var launchdJobs: @Sendable () -> [LaunchdJob]
    public var interval: Duration
    /// How long reading origin signals may take before the remaining processes are grouped without them.
    public var originBudget: Duration
    public var now: @Sendable () -> Date

    public init(source: any ProcessSource, hostCPU: any HostCPUSource, memory: any SystemMemorySource,
                origin: OriginSignalReader?, attribution: Attribution, launchdJobs: @escaping @Sendable () -> [LaunchdJob],
                interval: Duration = .seconds(1), originBudget: Duration = .seconds(20),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.hostCPU = hostCPU
        self.memory = memory
        self.origin = origin
        self.attribution = attribution
        self.launchdJobs = launchdJobs
        self.interval = interval
        self.originBudget = originBudget
        self.now = now
    }

    /// This Mac's, as the app reads it.
    public static func live() -> ProcessProbe {
        let launchd = LaunchdJobIndex()
        return ProcessProbe(source: LibprocProcessSource(), hostCPU: LiveHostCPUSource(), memory: LiveSystemMemorySource(),
                            origin: .live(launchd: launchd), attribution: Attribution(), launchdJobs: { launchd.jobs })
    }

    public func measure() async -> ProcessMeasurement {
        // Origin signals are read once, for the second sample, so the first two are `interval` apart.
        var sampler = Sampler(source: source, hostCPU: hostCPU)
        var firstSample = Set<ProcessIdentity>()
        let snapshot = await Result { () async throws -> ProcessSnapshot in
            firstSample = Set(try sampler.sample().processes.map(\.identity))
            try? await Task.sleep(for: interval)
            return try sampler.sample()
        }.mapError { ProcessSourceFailure(message: "\($0)") }
        let observedAt = now()
        let memory = SystemMemory(raw: memory.read())
        guard case let .success(sample) = snapshot else {
            return ProcessMeasurement(snapshot: snapshot, processes: [], attribution: nil, firstSample: firstSample,
                                      memory: memory, observedAt: observedAt)
        }
        var processes = sample.processes
        origin?.annotate(&processes, budget: originBudget)
        return ProcessMeasurement(snapshot: snapshot, processes: processes,
                                  attribution: attribution.attribute(processes, launchdJobs: launchdJobs()),
                                  firstSample: firstSample, memory: memory, observedAt: observedAt)
    }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

/// The `status` and `processes` results.
enum ProcessReports {
    static let topCount = 10

    static let groupSources: [(String, String)] = [
        ("groups", "Subset System's attribution rules over each process's executable path, parent chain, responsible process, coalition, code signature, launchd plists, and working directory"),
        ("groups.cpuPercent", "proc_pid_rusage user and system CPU time over two samples 1 second apart, summed per group; 100 is one logical core"),
        ("groups.memoryBytes", "proc_pid_rusage ri_phys_footprint, summed per group; approximate, since shared memory counts once per process")
    ]

    static func status(_ measurement: ProcessMeasurement, paths: PathDisplay) -> HelperReport {
        let memory = measurement.memory
        var errors = commonErrors(measurement)
        var cpuPercent: Double?
        var cores: Int?
        if case let .success(snapshot) = measurement.snapshot {
            cpuPercent = snapshot.machineCPUPercent
            cores = snapshot.logicalCoreCount
            if cpuPercent == nil {
                errors.append(HelperError(code: "cpuUnavailable", message: "The machine's CPU ticks could not be read."))
            }
        }
        let missing = [("pressure", memory.pressure == nil), ("swap", memory.swapUsed == nil),
                       ("compressed", memory.compressed == nil), ("used", memory.used == nil),
                       ("physical", memory.physicalMemory == nil)].filter(\.1).map(\.0)
        if !missing.isEmpty {
            errors.append(HelperError(code: "memoryUnavailable",
                                      message: "Could not read memory: \(missing.joined(separator: ", "))."))
        }
        let groups = measurement.attribution?.app ?? []
        let topCPU = top(groups, by: \.totals.cpuPercent.sum)
        let topMemory = top(groups, by: { $0.totals.memory.sum.map(Double.init) })
        let summary = { (group: OriginGroup) in summaryJSON(group, layer: .app, paths: paths) }
        let fields: [(String, JSONValue)] = [
            ("cpu", .object([("percent", .optional(cpuPercent)), ("logicalCores", .optional(cores))])),
            ("memory", .object([
                ("pressure", .optional(memory.pressure.map { $0.title.lowercased() })),
                ("physicalBytes", .optional(memory.physicalMemory)),
                ("usedBytes", .optional(memory.used)),
                ("appBytes", .optional(memory.app)),
                ("wiredBytes", .optional(memory.wired)),
                ("compressedBytes", .optional(memory.compressed)),
                ("swapUsedBytes", .optional(memory.swapUsed)),
                ("swapTotalBytes", .optional(memory.swapTotal))
            ])),
            ("processCount", processCount(measurement)),
            ("topByCPU", .array(topCPU.map(summary))),
            ("topByMemory", .array(topMemory.map(summary)))
        ]
        var lines = [
            "CPU: \(cpuPercent.map { percent($0) } ?? "unavailable")" + (cores.map { " of \($0) cores" } ?? "")
                + " · memory pressure: \(memory.pressure?.title ?? "unknown")",
            "Memory used: \(bytes(memory.used)) of \(bytes(memory.physicalMemory)) · compressed: \(bytes(memory.compressed))"
                + " · swap: \(bytes(memory.swapUsed)) of \(bytes(memory.swapTotal))"
        ]
        if !topCPU.isEmpty {
            lines.append("Top apps by CPU:")
            lines += topCPU.map { "  \(percent($0.totals.cpuPercent.sum ?? 0).padded(7))  \(paths.message($0.name))" }
        }
        if !topMemory.isEmpty {
            lines.append("Top apps by memory:")
            lines += topMemory.map { "  \(bytes($0.totals.memory.sum).padded(9))  \(paths.message($0.name))" }
        }
        return report("status", measurement, errors: errors, fields: fields, lines: lines, sources: [
            ("cpu.percent", "host_statistics HOST_CPU_LOAD_INFO ticks over two samples 1 second apart; includes restricted processes"),
            ("memory.pressure", "sysctl kern.memorystatus_vm_pressure_level"),
            ("memory.physicalBytes", "sysctl hw.memsize"),
            ("memory.swap", "sysctl vm.swapusage"),
            ("memory.usage", "host_statistics64 HOST_VM_INFO64: app (internal minus purgeable), wired, and compressor pages")
        ] + groupSources)
    }

    static func processes(_ measurement: ProcessMeasurement, layer: HelperLayer, paths: PathDisplay) -> HelperReport {
        let facts = Dictionary(measurement.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = measurement.attribution?.groups(layer.attribution) ?? []
        func detail(_ group: OriginGroup) -> JSONValue {
            guard case var .object(members) = summaryJSON(group, layer: layer, paths: paths) else { return .null }
            members.append(("members", .array(group.members.compactMap { identity in
                facts[identity].map { member($0, attribution: measurement.attribution?.attribution(of: identity),
                                             layer: layer, paths: paths) }
            })))
            members.append(("subgroups", .array(group.subgroups.map(detail))))
            return .object(members)
        }
        let lines = ["\(groups.count) \(layer.rawValue) groups:"] + groups.map {
            let totals = $0.totals
            return "  \(paths.message($0.name)): \(totals.processCount) processes, CPU \(totals.cpuPercent.sum.map { percent($0) } ?? "–"), memory \(bytes(totals.memory.sum))"
        }
        return report("processes", measurement, errors: commonErrors(measurement), fields: [
            ("layer", .string(layer.rawValue)),
            ("processCount", processCount(measurement)),
            ("groups", .array(groups.map(detail)))
        ], lines: lines, sources: groupSources + [
            ("members", "proc_listallpids with PROC_PIDTBSDINFO, proc_pidpath, and proc_pid_rusage per process; command-line arguments are never read")
        ])
    }

    private static func report(_ command: String, _ measurement: ProcessMeasurement, errors: [HelperError],
                               fields: [(String, JSONValue)], lines: [String], sources: [(String, String)]) -> HelperReport {
        let restricted = measurement.processes.filter(\.restricted).count
        var text = lines
        if restricted > 0 {
            text.append("\(restricted) processes are restricted by macOS; their usage is not in any total.")
        }
        text += errors.map { "Note: \($0.message)" }
        var exit: HelperExit?
        if case .failure = measurement.snapshot { exit = .internalError }
        return HelperReport(command: command, observedAt: measurement.observedAt, sources: sources,
                            restricted: [("processes", restricted)], errors: errors, fields: fields,
                            text: text.joined(separator: "\n"), exit: exit)
    }

    private static func commonErrors(_ measurement: ProcessMeasurement) -> [HelperError] {
        switch measurement.snapshot {
        case let .failure(failure):
            return [HelperError(code: "processListFailed", message: "Could not list processes: \(failure.message)")]
        case .success:
            var errors: [HelperError] = []
            // A process macOS restricts is counted in `restricted`; one whose usage read failed otherwise is an error.
            // One without CPU failed only if the first sample listed it; otherwise it started between the two samples.
            let unmeasured = measurement.processes.filter { process in
                !process.restricted && (process.physFootprint == nil
                    || process.cpuPercent == nil && measurement.firstSample.contains(process.identity))
            }.count
            if unmeasured > 0 {
                errors.append(HelperError(code: "usageUnavailable",
                                          message: "\(unmeasured) processes' CPU or memory could not be read; what was read is in the totals."))
            }
            let unread = measurement.processes.filter { $0.origin == nil }.count
            if unread > 0 {
                errors.append(HelperError(code: "originSignalsNotRead",
                                          message: "\(unread) processes' origin signals were not read in time, so fallback rules grouped them."))
            }
            return errors
        }
    }

    private static func processCount(_ measurement: ProcessMeasurement) -> JSONValue {
        if case .failure = measurement.snapshot { return .null }
        return .count(measurement.processes.count)
    }

    /// The `count` groups with the largest measured value, largest first, then in group order. A group without a
    /// measured value is left out rather than listed as zero.
    static func top(_ groups: [OriginGroup], by value: (OriginGroup) -> Double?, count: Int = topCount) -> [OriginGroup] {
        groups.compactMap { group in value(group).map { (group, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .prefix(count)
            .map(\.0)
    }

    private static func summaryJSON(_ group: OriginGroup, layer: HelperLayer, paths: PathDisplay) -> JSONValue {
        let (kind, value, path) = describe(group.id.origin)
        var id = kind + (value.map { ":" + (path != nil ? paths($0) : $0) } ?? "")
        if let subgroup = group.id.subgroup { id += "/" + paths(subgroup) }
        let totals = group.totals
        return .object([
            ("id", .string(id)),
            ("layer", .string(layer.rawValue)),
            ("kind", .string(kind)),
            ("name", .string(paths.message(group.name))),
            ("path", .optional(path.map(paths.callAsFunction))),
            ("processCount", .count(totals.processCount)),
            ("restrictedCount", .count(totals.restrictedCount)),
            ("cpuPercent", .optional(totals.cpuPercent.sum)),
            ("cpuUnmeasuredCount", .count(totals.cpuPercent.unmeasuredCount)),
            ("memoryBytes", .optional(totals.memory.sum)),
            ("memoryUnmeasuredCount", .count(totals.memory.unmeasuredCount))
        ])
    }

    private static func member(_ process: ProcessFacts, attribution: ProcessAttribution?, layer: HelperLayer,
                               paths: PathDisplay) -> JSONValue {
        let placement: (rule: String, confidence: AttributionConfidence)? = attribution.map { attribution in
            switch layer {
            case .app: ("\(attribution.app.rule)", attribution.app.confidence)
            case .vendor: ("\(attribution.vendor.rule)", attribution.vendor.confidence)
            case .launch: ("\(attribution.launchSource.rule)", attribution.launchSource.confidence)
            case .project: ("\(attribution.project.rule)", attribution.project.confidence)
            }
        }
        return .object([
            ("pid", .int(Int64(process.pid))),
            ("name", .string(process.name)),
            ("executable", .optional(process.executablePath.map(paths.callAsFunction))),
            ("restricted", .bool(process.restricted)),
            ("cpuPercent", .optional(process.cpuPercent)),
            ("memoryBytes", .optional(process.physFootprint)),
            ("rule", .optional(placement?.rule)),
            ("confidence", .optional(placement?.confidence.rawValue))
        ])
    }

    /// An origin's kind, its value, and the value again when it is a path.
    static func describe(_ origin: Origin) -> (kind: String, value: String?, path: String?) {
        switch origin {
        case let .app(path): ("app", path, path)
        case .macOS: ("macOS", nil, nil)
        case let .containerVM(name): ("containerVM", name, nil)
        case let .agent(name): ("agent", name, nil)
        case .terminal: ("terminal", nil, nil)
        case let .homebrew(formula): ("homebrew", formula, nil)
        case let .team(id): ("team", id, nil)
        case let .unattributed(executable): ("unattributed", executable, executable.hasPrefix("/") ? executable : nil)
        case .apple: ("apple", nil, nil)
        case let .vendor(teamID): ("vendor", teamID, nil)
        case .unsigned: ("unsigned", nil, nil)
        case .signatureUnavailable: ("signatureUnavailable", nil, nil)
        case let .launchdJob(label): ("launchdJob", label, nil)
        case let .loginItem(path): ("loginItem", path, path)
        case let .codingAgentSession(name): ("codingAgentSession", name, nil)
        case .terminalSession: ("terminalSession", nil, nil)
        case .appLaunched: ("appLaunched", nil, nil)
        case .system: ("system", nil, nil)
        case let .project(path): ("project", path, path)
        case .noProject: ("noProject", nil, nil)
        }
    }
}

func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value)
}

func bytes(_ value: UInt64?) -> String {
    value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "unknown"
}

extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
