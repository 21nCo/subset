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
    /// mounted under `volumesFolder`. A missing file or folder adds none; one that exists but cannot be read or parsed,
    /// a runtime bundle without a readable identifier included, makes the list unknown, since a runtime it would name
    /// may be installed.
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
        switch listing(volumesFolder) {
        case let .success(volumes):
            for volume in volumes where !volume.hasPrefix(".") {
                folders.append(volumesFolder + "/" + volume + "/Library/Developer/CoreSimulator/Profiles/Runtimes")
            }
        case let .failure(failure):
            return .unknown("\(volumesFolder) could not be read: \(failure.message).")
        }
        for folder in folders {
            let bundles: [String]
            switch listing(folder) {
            case let .success(names): bundles = names.filter { $0.hasSuffix(".simruntime") }
            case let .failure(failure): return .unknown("\(folder) could not be read: \(failure.message).")
            }
            for bundle in bundles {
                let plist = folder + "/" + bundle + "/Contents/Info.plist"
                switch PropertyListFile.read(plist) {
                case let .success(info):
                    guard let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else {
                        return .unknown("\(plist) has no bundle identifier.")
                    }
                    found.insert(id)
                case let .failure(failure):
                    return .unknown("\(plist) could not be read: \(failure.message).")
                }
            }
        }
        return .installed(found)
    }

    /// The names in a folder; none when it does not exist. A folder that is not downloaded is not.
    static func listing(_ path: String) -> Result<[String], PropertyListFile.Failure> {
        do {
            return .success(try PropertyListFile.withoutDownloading {
                try FileManager.default.contentsOfDirectory(atPath: path)
            }.sorted())
        } catch let error as NSError {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError || posix == Int(ENOENT) || posix == Int(ENOTDIR) {
                return .success([])
            }
            return .failure(.unreadable(posix.map { String(cString: strerror(Int32($0))) } ?? error.localizedDescription))
        }
    }

    /// The runtime of the simulator device in `folder` (`runtime` in its `device.plist`), or `nil` when unreadable.
    static func runtime(ofDevice folder: String) -> String? {
        guard case let .success(plist) = PropertyListFile.read(folder + "/device.plist") else { return nil }
        return plist["runtime"] as? String
    }
}

/// Reads a small property list file safely: a regular file of at most 1 MiB, opened without following a link or
/// blocking on a FIFO, and never downloaded when it is an iCloud placeholder.
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
        let read = withoutDownloading { () -> Result<Data, Failure> in
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable(String(cString: strerror(errno))))
            }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(.unreadable("not a regular file")) }
            guard info.st_flags & UInt32(bitPattern: SF_DATALESS) == 0 else { return .failure(.unreadable("not downloaded")) }
            guard info.st_size <= limit else { return .failure(.unreadable("larger than 1 MiB")) }
            var data = Data(count: Int(info.st_size))
            let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            return count == data.count ? .success(data) : .failure(.unreadable("could not be read"))
        }
        let data: Data
        switch read {
        case let .success(found): data = found
        case let .failure(failure): return .failure(failure)
        }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return .failure(.unreadable("not a property list dictionary"))
        }
        return .success(plist)
    }

    /// Runs `body` with this thread's reads of a dataless file or folder failing instead of downloading it, as the
    /// scan's threads read, then restores the thread's policy.
    static func withoutDownloading<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           previous >= 0 ? previous : IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
        }
        return try body()
    }
}
