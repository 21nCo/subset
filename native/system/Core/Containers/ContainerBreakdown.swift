import Foundation

/// One running container, as the runtime reports it from inside its VM: `docker ps` gives the identity and labels,
/// `docker stats --no-stream` the usage. A value the runtime did not report, or reported as `--`, is `nil`.
public struct Container: Equatable, Sendable {
    /// As the CLI prints it (12 characters unless `--no-trunc`).
    public let id: String
    public let name: String
    public let image: String?
    public let composeProject: String?
    /// Percent of one CPU inside the VM, where 100 is one fully used virtual core.
    public let cpuPercent: Double?
    /// Memory in use inside the VM, in bytes.
    public let memoryUsed: UInt64?
    /// The container's memory limit, in bytes; without a limit, the VM's memory.
    public let memoryLimit: UInt64?
}

/// Containers that share a `com.docker.compose.project` label.
public struct ComposeProject: Equatable, Sendable {
    public let name: String
    /// Ordered by name.
    public let containers: [Container]
    public let totals: ContainerTotals
}

/// Usage summed over containers. A container without a value is unmeasured, never zero.
public struct ContainerTotals: Equatable, Sendable {
    public let containerCount: Int
    public let memoryUsed: MetricTotal<UInt64>
    public let cpuPercent: MetricTotal<Double>

    init(_ containers: [Container]) {
        var memory = MetricTotal<UInt64>.Builder()
        var cpu = MetricTotal<Double>.Builder()
        for container in containers {
            memory.add(container.memoryUsed) { $0.addingSaturating($1) }
            cpu.add(container.cpuPercent) { $0 + $1 }
        }
        containerCount = containers.count
        memoryUsed = memory.total
        cpuPercent = cpu.total
    }
}

/// The containers a runtime reports inside its VM, sub-grouped by compose project. These are the runtime's own
/// figures, measured inside the VM; they are shown beside the VM's macOS footprint and never reconciled with it.
public struct ContainerBreakdown: Equatable, Sendable {
    /// Ordered by name.
    public let projects: [ComposeProject]
    /// Containers without a compose project, ordered by name.
    public let standalone: [Container]
    /// Every container.
    public let totals: ContainerTotals
    /// Output lines that were not a JSON object with an `ID`, skipped.
    public let skippedLines: Int
    /// Values present in a line that could not be read (not a number with a known unit), left `nil`.
    public let unreadableValues: Int

    /// Joins `docker ps` rows with `docker stats` rows by container ID, where one ID may be a prefix of the other,
    /// else by name. A container in only one of the two lists (one started or stopped between the commands) is kept,
    /// without usage or without labels.
    public init(listing: DockerOutput.Parsed<DockerOutput.Listing>, stats: DockerOutput.Parsed<DockerOutput.Stats>) {
        var unmatched = stats.rows
        var containers: [Container] = listing.rows.map { row in
            let match = unmatched.firstIndex { Self.sameContainer(row, $0) }.map { unmatched.remove(at: $0) }
            return Container(id: row.id, name: row.name, image: row.image, composeProject: row.composeProject,
                             cpuPercent: match?.cpuPercent, memoryUsed: match?.memoryUsed, memoryLimit: match?.memoryLimit)
        }
        containers += unmatched.map {
            Container(id: $0.id, name: $0.name ?? $0.id, image: nil, composeProject: nil,
                      cpuPercent: $0.cpuPercent, memoryUsed: $0.memoryUsed, memoryLimit: $0.memoryLimit)
        }
        containers.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        projects = Dictionary(grouping: containers.filter { $0.composeProject != nil }) { $0.composeProject ?? "" }
            .sorted { $0.key < $1.key }
            .map { ComposeProject(name: $0.key, containers: $0.value, totals: ContainerTotals($0.value)) }
        standalone = containers.filter { $0.composeProject == nil }
        totals = ContainerTotals(containers)
        skippedLines = listing.skippedLines + stats.skippedLines
        unreadableValues = listing.unreadableValues + stats.unreadableValues
    }

    private static func sameContainer(_ listing: DockerOutput.Listing, _ stats: DockerOutput.Stats) -> Bool {
        if !listing.id.isEmpty, !stats.id.isEmpty, listing.id.hasPrefix(stats.id) || stats.id.hasPrefix(listing.id) { return true }
        return stats.name == listing.name
    }
}

/// Parses the JSON lines `docker ps --format '{{json .}}'` and `docker stats --no-stream --format '{{json .}}'`
/// print, one object per container.
public enum DockerOutput {
    public static let composeProjectLabel = "com.docker.compose.project"

    /// The rows read from one command's output, and what could not be read.
    public struct Parsed<Row: Equatable & Sendable>: Equatable, Sendable {
        public let rows: [Row]
        /// Non-empty lines that were not a JSON object with a non-empty `ID`.
        public let skippedLines: Int
        public let unreadableValues: Int

        /// The output had lines but none could be read, so it says nothing about the containers.
        public var isUnparsable: Bool { rows.isEmpty && skippedLines > 0 }
    }

    /// A `docker ps` row.
    public struct Listing: Equatable, Sendable {
        public let id: String
        /// The first of `Names`.
        public let name: String
        public let image: String?
        public let composeProject: String?
    }

    /// A `docker stats` row.
    public struct Stats: Equatable, Sendable {
        public let id: String
        public let name: String?
        public let cpuPercent: Double?
        public let memoryUsed: UInt64?
        public let memoryLimit: UInt64?
    }

    public static func listing(_ output: String) -> Parsed<Listing> {
        parse(output) { object, _ in
            guard let id = nonEmpty(object["ID"]) else { return nil }
            let name = nonEmpty(object["Names"]).flatMap { $0.split(separator: ",").first.map(String.init) } ?? id
            return Listing(id: id, name: name, image: nonEmpty(object["Image"]),
                           composeProject: (object["Labels"] as? String).flatMap(composeProject(labels:)))
        }
    }

    public static func stats(_ output: String) -> Parsed<Stats> {
        parse(output) { object, unreadable in
            guard let id = nonEmpty(object["ID"]) else { return nil }
            let usage = (object["MemUsage"] as? String).map { $0.components(separatedBy: " / ") }
            return Stats(id: id, name: nonEmpty(object["Name"]),
                         cpuPercent: read(object["CPUPerc"], percent, &unreadable),
                         memoryUsed: read(usage?.first, bytes, &unreadable),
                         memoryLimit: read(usage.flatMap { $0.count == 2 ? $0[1] : nil }, bytes, &unreadable))
        }
    }

    /// The compose project in a `Labels` value, `k=v` pairs joined by commas. Compose project names hold only
    /// lowercase letters, digits, `-`, and `_`, so a comma never appears inside one.
    static func composeProject(labels: String) -> String? {
        let prefix = composeProjectLabel + "="
        return labels.split(separator: ",").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `12.34%` as 12.34.
    static func percent(_ text: String) -> Double? {
        guard text.hasSuffix("%"), let value = Double(text.dropLast().trimmingCharacters(in: .whitespaces)),
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// A size as the Docker CLI prints it: binary units (`B`, `KiB`, `MiB`, `GiB`, `TiB`, `PiB`) for memory, decimal
    /// ones (`kB`, `MB`, `GB`, `TB`, `PB`) for I/O. Rounded to whole bytes.
    static func bytes(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let unitStart = trimmed.firstIndex(where: { $0.isLetter }),
              let value = Double(trimmed[..<unitStart].trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0,
              let scale = byteUnits[String(trimmed[unitStart...])] else { return nil }
        let result = (value * scale).rounded()
        return result < 0x1p64 ? UInt64(result) : nil
    }

    private static let byteUnits: [String: Double] = [
        "B": 1,
        "KiB": 0x1p10, "MiB": 0x1p20, "GiB": 0x1p30, "TiB": 0x1p40, "PiB": 0x1p50,
        "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15
    ]

    /// Reads a value that is present; a missing value, an empty one, or the CLI's `--` placeholder is `nil` without
    /// counting as unreadable.
    private static func read<Value>(_ raw: Any?, _ parse: (String) -> Value?, _ unreadable: inout Int) -> Value? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text != "--" else {
            if raw != nil, !(raw is String) { unreadable += 1 }
            return nil
        }
        guard let value = parse(text) else { unreadable += 1; return nil }
        return value
    }

    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    private static func parse<Row: Equatable & Sendable>(_ output: String, _ row: ([String: Any], inout Int) -> Row?) -> Parsed<Row> {
        var rows: [Row] = []
        var skipped = 0
        var unreadable = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any],
                  let parsed = row(object, &unreadable) else {
                skipped += 1
                continue
            }
            rows.append(parsed)
        }
        return Parsed(rows: rows, skippedLines: skipped, unreadableValues: unreadable)
    }
}
