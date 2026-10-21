import Darwin
import Foundation

/// The simulator runtimes installed on this Mac, by identifier (`com.apple.CoreSimulator.SimRuntime.iOS-18-3`), which
/// decide which simulator devices are unavailable. Read from files, without running `simctl`.
public enum SimulatorRuntimes: Equatable, Sendable {
    case installed(Set<String>)
    /// The list could not be read, so no device is called unavailable.
    case unknown(String)

    public static let imagesPlist = "/Library/Developer/CoreSimulator/Images/images.plist"
    public static let runtimesFolder = "/Library/Developer/CoreSimulator/Profiles/Runtimes"
    public static let volumesFolder = "/Library/Developer/CoreSimulator/Volumes"

    /// Reads the runtime disk images CoreSimulator registers (`runtimeInfo.bundleIdentifier` of each entry in
    /// `images.plist`) and the runtime bundles installed as folders: in `runtimesFolder` and in the runtime volumes
    /// mounted under `volumesFolder`. A missing file or folder adds none; an `images.plist` that cannot be read or
    /// parsed makes the list unknown.
    public static func read(imagesPlist: String = imagesPlist, runtimesFolder: String = runtimesFolder,
                            volumesFolder: String = volumesFolder) -> SimulatorRuntimes {
        var found: Set<String> = []
        switch PropertyListFile.read(imagesPlist) {
        case let .success(plist):
            guard let images = plist["images"] as? [[String: Any]] else {
                return .unknown("\(imagesPlist) has no list of images.")
            }
            for image in images {
                if let info = image["runtimeInfo"] as? [String: Any], let id = info["bundleIdentifier"] as? String {
                    found.insert(id)
                }
            }
        case .failure(.missing):
            break
        case let .failure(failure):
            return .unknown("\(imagesPlist) could not be read: \(failure.message).")
        }
        var folders = [runtimesFolder]
        for volume in InstalledApps.listing(volumesFolder) where !volume.hasPrefix(".") {
            folders.append(volumesFolder + "/" + volume + "/Library/Developer/CoreSimulator/Profiles/Runtimes")
        }
        for folder in folders {
            for bundle in InstalledApps.listing(folder) where bundle.hasSuffix(".simruntime") {
                if case let .success(info) = PropertyListFile.read(folder + "/" + bundle + "/Contents/Info.plist"),
                   let id = info["CFBundleIdentifier"] as? String {
                    found.insert(id)
                }
            }
        }
        return .installed(found)
    }

    /// The runtime of the simulator device in `folder` (`runtime` in its `device.plist`), or `nil` when unreadable.
    static func runtime(ofDevice folder: String) -> String? {
        guard case let .success(plist) = PropertyListFile.read(folder + "/device.plist") else { return nil }
        return plist["runtime"] as? String
    }
}

/// Reads a small property list file safely: a regular file of at most 1 MiB, opened without following a link or
/// blocking on a FIFO.
enum PropertyListFile {
    static let limit = 1 << 20

    enum Failure: Error, Equatable {
        case missing
        case unreadable(String)

        var message: String {
            switch self {
            case .missing: "not found"
            case let .unreadable(message): message
            }
        }
    }

    static func read(_ path: String) -> Result<[String: Any], Failure> {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable(String(cString: strerror(errno))))
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(.unreadable("not a regular file")) }
        guard info.st_size <= limit else { return .failure(.unreadable("larger than 1 MiB")) }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { return .failure(.unreadable("could not be read")) }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return .failure(.unreadable("not a property list dictionary"))
        }
        return .success(plist)
    }
}
