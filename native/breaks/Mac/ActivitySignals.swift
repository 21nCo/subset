import AppKit
import CoreAudio
import CoreGraphics
import CoreMediaIO
import IOKit.pwr_mgt

/// Reads the public macOS signals that drive idle detection and smart pause. Nothing here records audio
/// or video, reads window contents, or needs a privacy permission: it asks whether a device or assertion is
/// in use, and which app is frontmost.
@MainActor
struct ActivitySignals {
    struct Reading: Equatable {
        var idleSeconds: TimeInterval
        var signals: Set<PauseReason>
        var frontmostAppName: String?
    }

    func read(settings: BreakSettings) -> Reading {
        var signals: Set<PauseReason> = []
        let smart = settings.smartPause
        if smart.meetingsAndCalls, Self.isMicrophoneInUse() || Self.isCameraInUse() {
            signals.insert(.meeting)
        }
        if smart.mediaPlayback, Self.isDisplaySleepPrevented() {
            signals.insert(.media)
        }
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            if smart.deepFocusApps,
               let bundleID = front.bundleIdentifier,
               settings.desktop.pauseApps.contains(where: { $0.bundleID == bundleID }) {
                signals.insert(.app)
            }
            if smart.games, Self.isGame(front) {
                signals.insert(.game)
            }
        }
        return Reading(
            idleSeconds: settings.desktop.idle.isEnabled ? Self.idleSeconds() : 0,
            signals: signals,
            frontmostAppName: front?.localizedName
        )
    }

    // MARK: - Idle

    /// Seconds since the last keyboard, mouse, trackpad, or tablet event in this login session.
    static func idleSeconds() -> TimeInterval {
        // kCGAnyInputEventType (~0) covers every input event type.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: - Microphone

    /// True when any other process is capturing audio input. On macOS 14.2+ this uses the per-process
    /// Core Audio objects; earlier systems fall back to "an input-only device is running".
    static func isMicrophoneInUse() -> Bool {
        if #available(macOS 14.2, *) {
            if let inUse = anyProcessCapturingInput() { return inUse }
        }
        return anyInputDeviceRunning()
    }

    @available(macOS 14.2, *)
    private static func anyProcessCapturingInput() -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard let processes: [AudioObjectID] = audioObjectList(AudioObjectID(kAudioObjectSystemObject), &address) else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for process in processes {
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &size, &running) == noErr, running != 0 else { continue }

            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid == ownPID { continue }
            return true
        }
        return false
    }

    private static func anyInputDeviceRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard let devices: [AudioDeviceID] = audioObjectList(AudioObjectID(kAudioObjectSystemObject), &address) else { return false }
        // "Running somewhere" also covers output, so a duplex device (a headset, or a USB interface) that is
        // only playing audio would look like a call. Only input-only devices, such as the built-in
        // microphone, are counted; a call on a duplex headset is missed on these older systems.
        for device in devices where hasStreams(device, scope: kAudioObjectPropertyScopeInput) && !hasStreams(device, scope: kAudioObjectPropertyScopeOutput) {
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &size, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    private static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func audioObjectList<T>(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> [T]? {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr else { return nil }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    // MARK: - Camera

    /// True when any camera is in use by any process (the same state that lights the camera indicator).
    static func isCameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.stride
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }

        for device in devices {
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
            )
            var running: UInt32 = 0
            var runningUsed: UInt32 = 0
            let status = CMIOObjectGetPropertyData(
                device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &runningUsed, &running
            )
            if status == noErr, running != 0 { return true }
        }
        return false
    }

    // MARK: - Display-sleep assertions

    /// True when another process holds a power assertion that keeps the display awake. Video players,
    /// browsers playing video, presentation apps, and call apps take this assertion; so do keep-awake
    /// utilities, which therefore also trigger this pause.
    static func isDisplaySleepPrevented() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displayTypes: Set<String> = [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypeNoDisplaySleep]
        for (pid, assertions) in byProcess where pid.int32Value != ownPID {
            for assertion in assertions {
                if let type = assertion[kIOPMAssertionTypeKey] as? String, displayTypes.contains(type) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Games

    /// True when the app declares a games category in its Info.plist (`LSApplicationCategoryType`).
    static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL,
              let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String else { return false }
        return category.hasPrefix("public.app-category.") && category.hasSuffix("games")
    }
}
