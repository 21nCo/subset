import Foundation

/// The image space the Docker CLI reports inside the VM: the `Images` row of `docker system df`.
public struct DockerImageSpace: Equatable, Sendable {
    /// Images, and those a container uses.
    public let count: Int?
    public let active: Int?
    /// The space all images use.
    public let size: UInt64?
    /// The space of images no container uses. `docker image prune -f` removes only dangling ones (untagged), so it may
    /// free less.
    public let reclaimable: UInt64?

    public init(count: Int?, active: Int?, size: UInt64?, reclaimable: UInt64?) {
        self.count = count
        self.active = active
        self.size = size
        self.reclaimable = reclaimable
    }
}

/// One `docker system df` run: the image space, or why there is none.
public enum DockerImageUsage: Equatable, Sendable {
    case reported(DockerImageSpace, observedAt: Date)
    case unavailable(ContainerUnavailable)
}

extension DockerCLI {
    public static let diskUsageArguments = ["system", "df", "--format", "json"]
    /// `docker system df` sizes every image, container, and volume, so it gets longer than the container poll.
    public static let diskUsageTimeout: Duration = .seconds(30)

    /// Runs `docker system df --format json`, pinned like the container poll to the real path of the current
    /// context's socket, and reads its `Images` row. A missing CLI, an unrecognized or remote context, a stopped
    /// daemon, a failure, or output without a readable `Images` row is unavailable with the reason.
    public func imageUsage(at date: Date = Date(), timeout: Duration = DockerCLI.diskUsageTimeout) async -> DockerImageUsage {
        switch target() {
        case let .unavailable(_, _, reason):
            return .unavailable(reason)
        case let .ready(cli, _, endpoint):
            switch await run(cli, Self.diskUsageArguments, host: endpoint, timeout: timeout) {
            case let .failure(reason): return .unavailable(reason)
            case let .success(text):
                guard let space = DockerOutput.imageSpace(text) else {
                    return .unavailable(.unparsableOutput(command: Self.commandName(Self.diskUsageArguments)))
                }
                return .reported(space, observedAt: date)
            }
        }
    }
}

extension DockerOutput {
    /// The `Images` row of `docker system df --format json`, one JSON object per line (`Type`, `TotalCount`,
    /// `Active`, `Size`, `Reclaimable` such as `1.2GB (45%)`), or `nil` when no line is a readable `Images` row. A
    /// value that is missing or not a known size is `nil`.
    public static func imageSpace(_ output: String) -> DockerImageSpace? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["Type"] as? String == "Images" else { continue }
            let reclaimable = (object["Reclaimable"] as? String).map { text in
                // The share of the total follows in parentheses.
                String(text.prefix { $0 != "(" })
            }
            let space = DockerImageSpace(count: count(object["TotalCount"]), active: count(object["Active"]),
                                         size: (object["Size"] as? String).flatMap(bytes),
                                         reclaimable: reclaimable.flatMap(bytes))
            guard space.size != nil || space.reclaimable != nil else { return nil }
            return space
        }
        return nil
    }

    /// A count the CLI prints as a string (`"12"`) or a number.
    private static func count(_ raw: Any?) -> Int? {
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        return nil
    }
}
