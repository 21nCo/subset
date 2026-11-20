import Foundation

/// Attaches and detaches a downloaded disk image; `HdiutilDiskImages` uses /usr/bin/hdiutil, tests a folder.
public protocol DiskImageAttaching: Sendable {
    /// Attaches `image` read-only and hidden, mounting its volumes in new folders inside `mountRoot`, and returns the
    /// devices it attached (empty when they are not known). Throws an InstallFailure (step image) when it cannot, or
    /// CancellationError.
    func attach(_ image: URL, mountRoot: URL) async throws -> [String]
    /// Detaches `image` wherever it is attached, first by `devices`, and returns whether it is no longer attached. Never
    /// cancelled.
    func detach(_ image: URL, devices: [String]) async -> Bool
}

/// hdiutil, as install.mjs runs it: `attach -readonly -nobrowse -noautoopen -mountrandom`, and on cleanup `detach` by
/// device (forced when a plain detach fails) until `hdiutil info` lists none of the image's devices, three times at most.
public struct HdiutilDiskImages: DiskImageAttaching {
    static let hdiutil = "/usr/bin/hdiutil"

    public init() {}

    public func attach(_ image: URL, mountRoot: URL) async throws -> [String] {
        let run = try await ToolRunner.run(
            Self.hdiutil, ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountrandom", mountRoot.path, "-plist", image.path]
        )
        guard run.status == 0 else { throw InstallFailure(.image, "hdiutil could not attach the image (\(run.lastLine))") }
        return Self.wholeDisks(in: Self.plist(run.stdout)?["system-entities"])
    }

    public func detach(_ image: URL, devices: [String]) async -> Bool {
        var devices = devices
        for attempt in 0..<3 {
            for device in Set(devices) {
                let plain = try? await ToolRunner.run(Self.hdiutil, ["detach", device, "-quiet"], timeout: 60, cancellable: false)
                if plain?.status != 0 {
                    _ = try? await ToolRunner.run(Self.hdiutil, ["detach", device, "-force", "-quiet"], timeout: 60, cancellable: false)
                }
            }
            guard let left = await attachedDevices(of: image) else {
                devices = []
                continue
            }
            if left.isEmpty { return true }
            devices = left
            if attempt < 2 { await ToolRunner.pause(nanoseconds: 1_000_000_000) }
        }
        return false
    }

    // The devices `hdiutil info` lists for `image`, or nil when hdiutil info fails.
    private func attachedDevices(of image: URL) async -> [String]? {
        guard let run = try? await ToolRunner.run(Self.hdiutil, ["info", "-plist"], timeout: 60, cancellable: false),
              run.status == 0, let info = Self.plist(run.stdout)
        else { return nil }
        return Self.devices(of: image, in: info)
    }

    /// The whole-disk devices `hdiutil info` lists for `image`, matched by any name `imagePaths` gives it in either its
    /// image-path or its image-alias (which may be the only one with the name it was attached by).
    static func devices(of image: URL, in info: [String: Any]) -> [String] {
        let names = imagePaths(of: image)
        let images = info["images"] as? [[String: Any]] ?? []
        return images.filter { entry in ["image-path", "image-alias"].contains { names.contains(entry[$0] as? String ?? "") } }
            .flatMap { wholeDisks(in: $0["system-entities"]) }
    }

    /// The names `hdiutil info` may give `image`, as install.mjs matches them: the path it was attached with and its
    /// real path, the folder resolved by realpath(3) so /var/folders/... is also /private/var/folders/... (Foundation's
    /// resolvingSymlinksInPath drops /private instead), plus Foundation's spelling.
    static func imagePaths(of image: URL) -> Set<String> {
        var names: Set<String> = [image.path, image.resolvingSymlinksInPath().path]
        if let folder = AppInstaller.realPath(image.deletingLastPathComponent().path) {
            names.insert((folder as NSString).appendingPathComponent(image.lastPathComponent))
        }
        return names
    }

    static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // The whole-disk devices (/dev/diskN) among hdiutil's system entities.
    private static func wholeDisks(in entities: Any?) -> [String] {
        (entities as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }.filter {
            $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
        }
    }
}
