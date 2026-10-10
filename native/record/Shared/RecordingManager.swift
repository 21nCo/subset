import AVFoundation
import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    let duration: TimeInterval

    var id: String { url.path }
}

@MainActor
final class RecordingManager: NSObject, ObservableObject {
    private static let waveformSampleCount = 72
    private static let liveActivityUpdateInterval: TimeInterval = 1.25
    private static let supportedRecordingExtensions: Set<String> = ["m4a", "caf", "wav", "aac"]
    private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var waveformSamples: [CGFloat] = []
    @Published var outputURL: URL?
    @Published var errorMessage: String?
    @Published var statusMessage = "Ready to capture audio."
    @Published var permissionStatusText = "Unknown"
    @Published private(set) var savedRecordings: [RecordingItem] = []
    @Published private(set) var playingRecordingURL: URL?
    @Published private(set) var playbackTime: TimeInterval = 0
    @Published private(set) var playbackProgress: Double = 0
    @Published private(set) var playbackWaveformSamples: [CGFloat] = []
    #if os(iOS)
    @Published private(set) var isLiveActivityActive = false
    #endif

    var surfaceStatusText: String {
        #if os(iOS)
        guard isRecording else { return "Live Activity idle" }
        return isLiveActivityActive ? "Live Activity armed" : "Live Activity unavailable"
        #elseif os(macOS)
        return isRecording ? "Floating panel open" : "Floating panel idle"
        #else
        return isRecording ? "Recording active" : "Idle"
        #endif
    }

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var statusTimer: Timer?
    private var playbackTimer: Timer?
    private var recordingStartedAt: Date?
    private var lastActivityUpdate = Date.distantPast
    private var waveformCache: [String: [CGFloat]] = [:]
    private var waveformGenerationInFlight: Set<String> = []
    /// True while a start is waiting for permission or setup, so a second Start cannot overlap it.
    private var isStartingRecording = false

    #if os(iOS)
    private let activityBridge = RecordingActivityBridge()
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var pendingVisibilityAlert = false
    #endif

    override init() {
        super.init()
        updatePermissionStatusLabel()
        refreshSavedRecordings()

        #if os(iOS)
        Task {
            await activityBridge.cleanupOrphanedActivities()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        #elseif os(macOS)
        // Finalize the file if the app quits mid-recording, so the folder holds a playable clip.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }

    #if os(iOS)
    /// A call, alarm, or Siri can pause capture. Stop and save rather than keep claiming to record.
    @objc nonisolated private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: rawType) == .began
        else { return }

        Task { @MainActor [weak self] in
            self?.stopRecordingAfterSystemInterruption(
                message: "Recording stopped because another app or a call interrupted audio. The clip up to that point is saved."
            )
        }
    }
    #elseif os(macOS)
    @objc nonisolated private func handleApplicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            stopRecording()
        }
    }
    #endif

    /// Re-reads the recordings folder, which is the source of truth, e.g. when the app becomes active.
    func reloadSavedRecordings() {
        refreshSavedRecordings()
    }

    private func stopRecordingAfterSystemInterruption(message: String) {
        guard isRecording else { return }
        stopRecording()
        statusMessage = message
    }

    func toggleRecording() {
        Task {
            if isRecording {
                stopRecording()
            } else {
                await startRecording()
            }
        }
    }

    /// Permanently deletes a saved recording after the caller has confirmed it.
    func deleteRecording(_ recording: RecordingItem) {
        guard !isRecording || outputURL != recording.url else { return }
        if playingRecordingURL == recording.url {
            stopPlayback()
        }

        do {
            try FileManager.default.removeItem(at: recording.url)
            waveformCache.removeValue(forKey: recording.id)
            statusMessage = "Recording deleted."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Unable to delete the recording."
        }
        refreshSavedRecordings()
    }

    var isPermissionDenied: Bool {
        permissionStatusText == "Denied"
    }

    /// Opens the system settings page where microphone access can be changed.
    func openMicrophoneSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    func resetVisualization() {
        waveformSamples = []
        if !isRecording {
            elapsedTime = 0
        }
        errorMessage = nil
        statusMessage = "Waveform reset and ready."
    }

    func togglePlayback(for recording: RecordingItem) {
        if playingRecordingURL == recording.url {
            stopPlayback()
        } else {
            startPlayback(recording)
        }
    }

    func isPlaying(_ recording: RecordingItem) -> Bool {
        playingRecordingURL == recording.url
    }

    func waveformPreviewSamples(for recording: RecordingItem) -> [CGFloat] {
        cachedWaveformSamples(for: recording)
    }

    func seekPlayback(to progress: CGFloat) {
        guard let audioPlayer else { return }

        let clampedProgress = min(max(progress, 0), 1)
        audioPlayer.currentTime = audioPlayer.duration * Double(clampedProgress)

        if !audioPlayer.isPlaying {
            audioPlayer.play()
        }

        tickPlaybackState()
    }

    private func startRecording() async {
        guard !isRecording, !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }

        errorMessage = nil
        stopPlayback(deactivateSession: false, updateStatus: false)

        let granted = await requestPermissionIfNeeded()
        guard granted else {
            statusMessage = "Microphone access is required before recording can begin."
            errorMessage = "Permission denied. Enable microphone access in Settings and try again."
            return
        }

        do {
            try configureAudioSessionIfNeeded()
            let outputURL = try makeOutputURL()
            try startAudioRecorderRecording(to: outputURL)
            let startedAt = Date()

            self.outputURL = outputURL
            recordingStartedAt = startedAt
            elapsedTime = 0
            lastActivityUpdate = .distantPast
            waveformSamples = []
            isRecording = true
            statusMessage = "Recording. The clip is saved on this device as it records."
            updatePermissionStatusLabel()
            startStatusLoop()
            beginBackgroundAssertionIfNeeded()

            #if os(iOS)
            pendingVisibilityAlert = false
            isLiveActivityActive = false
            let activityStarted = await activityBridge.start(startedAt: startedAt, samples: activitySamples(from: waveformSamples).map(Double.init))
            // The recording may have stopped while the activity request was pending.
            isLiveActivityActive = activityStarted && isRecording
            lastActivityUpdate = .now
            #endif
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Failed to begin recording."
            stopStatusLoop()
            stopAudioRecorder()
            deactivateAudioSessionIfNeeded()
            endBackgroundAssertionIfNeeded()
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        stopStatusLoop()
        stopAudioRecorder()
        isRecording = false

        let startedAt = recordingStartedAt ?? .now
        elapsedTime = Date().timeIntervalSince(startedAt)
        lastActivityUpdate = .distantPast
        statusMessage = "Saved. The new clip is ready to play."
        deactivateAudioSessionIfNeeded()
        endBackgroundAssertionIfNeeded()
        refreshSavedRecordings()

        #if os(iOS)
        pendingVisibilityAlert = false
        isLiveActivityActive = false
        let samples = activitySamples(from: waveformSamples).map(Double.init)
        Task {
            await activityBridge.end(startedAt: startedAt, samples: samples)
        }
        #endif
    }

    private func startAudioRecorderRecording(to url: URL) throws {
        stopAudioRecorder()

        let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw NSError(
                domain: "dev.subset.record",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The recorder could not start capturing audio."]
            )
        }

        audioRecorder = recorder
    }

    private func stopAudioRecorder() {
        // Clear the reference first so the delegate callback for this stop is recognized as ours.
        let recorder = audioRecorder
        audioRecorder = nil
        recorder?.stop()
    }

    /// The recorder finished or failed without our stopRecording() call (system stop or encode error).
    private func handleRecorderEndedUnexpectedly(_ recorderID: ObjectIdentifier, errorDescription: String?) {
        guard isRecording, let audioRecorder, ObjectIdentifier(audioRecorder) == recorderID else { return }
        stopRecording()
        if let errorDescription {
            errorMessage = errorDescription
        }
        statusMessage = "Recording stopped unexpectedly. The clip up to that point is saved."
    }

    private func startStatusLoop() {
        stopStatusLoop()

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickRecordingState()
            }
        }

        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopStatusLoop() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func tickRecordingState() {
        guard isRecording, let audioRecorder else { return }

        if let recordingStartedAt {
            elapsedTime = Date().timeIntervalSince(recordingStartedAt)
        }

        audioRecorder.updateMeters()
        appendWaveformLevel(
            Self.waveformLevel(
                averagePower: audioRecorder.averagePower(forChannel: 0),
                peakPower: audioRecorder.peakPower(forChannel: 0)
            )
        )
    }

    private func appendWaveformLevel(_ level: CGFloat) {
        let smoothedLevel: CGFloat
        if let lastSample = waveformSamples.last {
            smoothedLevel = lastSample * 0.28 + level * 0.72
        } else {
            smoothedLevel = level
        }

        waveformSamples = Array((waveformSamples + [smoothedLevel]).suffix(Self.waveformSampleCount))
        pushLiveActivityUpdateIfNeeded()
    }

    private func makeOutputURL() throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fileName = "recording-\(formatter.string(from: .now)).m4a"
        let recordingsFolder = try recordingsFolderURL()
        return recordingsFolder.appendingPathComponent(fileName, isDirectory: false)
    }

    private func activitySamples(from bins: [CGFloat]) -> [CGFloat] {
        bins
    }

    private func pushLiveActivityUpdateIfNeeded() {
        #if os(iOS)
        guard isRecording, let recordingStartedAt else { return }
        guard Date().timeIntervalSince(lastActivityUpdate) >= Self.liveActivityUpdateInterval else { return }

        lastActivityUpdate = .now
        let shouldAlert = pendingVisibilityAlert
        pendingVisibilityAlert = false
        let samples = activitySamples(from: waveformSamples).map(Double.init)
        Task {
            await activityBridge.update(
                startedAt: recordingStartedAt,
                samples: samples,
                includeAlert: shouldAlert
            )
        }
        #endif
    }

    private func refreshSavedRecordings() {
        do {
            savedRecordings = try loadSavedRecordings()
            warmWaveformCache(for: savedRecordings)
            if !isRecording {
                outputURL = savedRecordings.first?.url
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Unable to load locally saved recordings."
        }
    }

    private func loadSavedRecordings() throws -> [RecordingItem] {
        let folder = try recordingsFolderURL()
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        let recordings = urls.compactMap { url -> RecordingItem? in
            guard Self.supportedRecordingExtensions.contains(url.pathExtension.lowercased()) else {
                return nil
            }

            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile != false else {
                return nil
            }

            let createdAt = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
            return RecordingItem(
                url: url,
                createdAt: createdAt,
                duration: Self.duration(for: url)
            )
        }
        .sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }

            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }

        // Recordings are only removed by an explicit delete; there is no automatic cap.
        return recordings
    }

    private func recordingsFolderURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let recordingsFolder = root.appendingPathComponent("Subset Record", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        return recordingsFolder
    }

    private func startPlayback(_ recording: RecordingItem) {
        guard !isRecording else {
            statusMessage = "Stop the current recording before playing a saved clip."
            return
        }

        errorMessage = nil

        do {
            try configurePlaybackSessionIfNeeded()
            let player = try AVAudioPlayer(contentsOf: recording.url)
            player.delegate = self
            player.prepareToPlay()

            stopPlayback(deactivateSession: false, updateStatus: false)

            audioPlayer = player
            playingRecordingURL = recording.url
            playbackTime = 0
            playbackProgress = 0
            playbackWaveformSamples = cachedWaveformSamples(for: recording)

            guard player.play() else {
                throw NSError(
                    domain: "dev.subset.record",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "The saved recording could not start playback."]
                )
            }

            statusMessage = "Playing \(recording.url.lastPathComponent)."
            startPlaybackLoop()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Playback failed."
            stopPlayback(deactivateSession: true, updateStatus: false)
        }
    }

    func stopPlayback() {
        stopPlayback(deactivateSession: true, updateStatus: true)
    }

    private func stopPlayback(deactivateSession: Bool, updateStatus: Bool) {
        let didHaveActivePlayback = audioPlayer != nil || playingRecordingURL != nil

        audioPlayer?.stop()
        audioPlayer = nil
        stopPlaybackLoop()
        playingRecordingURL = nil
        playbackTime = 0
        playbackProgress = 0
        playbackWaveformSamples = []

        if deactivateSession, !isRecording {
            deactivatePlaybackSessionIfNeeded()
        }

        if updateStatus, didHaveActivePlayback, !isRecording {
            statusMessage = "Playback stopped."
        }
    }

    private func startPlaybackLoop() {
        stopPlaybackLoop()

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickPlaybackState()
            }
        }

        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlaybackLoop() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func tickPlaybackState() {
        guard let audioPlayer else { return }

        playbackTime = audioPlayer.currentTime
        if audioPlayer.duration > 0 {
            playbackProgress = min(max(audioPlayer.currentTime / audioPlayer.duration, 0), 1)
        } else {
            playbackProgress = 0
        }
    }

    private func handlePlaybackFinished(successfully: Bool) {
        stopPlayback(deactivateSession: true, updateStatus: false)
        statusMessage = successfully ? "Playback finished." : "Playback ended unexpectedly."
    }

    private func warmWaveformCache(for recordings: [RecordingItem]) {
        let validIDs = Set(recordings.map(\.id))
        waveformCache = waveformCache.filter { validIDs.contains($0.key) }
        waveformGenerationInFlight = waveformGenerationInFlight.filter { validIDs.contains($0) }

        for recording in recordings {
            generateWaveformSamplesIfNeeded(for: recording)
        }
    }

    private func cachedWaveformSamples(for recording: RecordingItem) -> [CGFloat] {
        if let cached = waveformCache[recording.id] {
            return cached
        }

        generateWaveformSamplesIfNeeded(for: recording)
        return Self.placeholderWaveformSamples
    }

    private func generateWaveformSamplesIfNeeded(for recording: RecordingItem) {
        guard waveformCache[recording.id] == nil else { return }
        guard waveformGenerationInFlight.insert(recording.id).inserted else { return }

        let recordingID = recording.id
        let recordingURL = recording.url
        let sampleCount = Self.waveformSampleCount

        Task.detached(priority: .utility) { [weak self] in
            let samples = Self.waveformSamples(for: recordingURL, sampleCount: sampleCount)
            await self?.storeGeneratedWaveformSamples(samples, for: recordingID, recordingURL: recordingURL)
        }
    }

    private func storeGeneratedWaveformSamples(_ samples: [CGFloat], for recordingID: String, recordingURL: URL) {
        waveformGenerationInFlight.remove(recordingID)
        // The cache is not @Published; notify so rows replace their placeholder bars.
        objectWillChange.send()
        waveformCache[recordingID] = samples

        if playingRecordingURL == recordingURL {
            playbackWaveformSamples = samples
        }
    }

    #if os(iOS)
    func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active, !isRecording {
            refreshSavedRecordings()
        }
        guard isRecording else { return }
        pendingVisibilityAlert = phase == .background
    }
    #endif

    private func updatePermissionStatusLabel() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permissionStatusText = "Granted"
        case .denied:
            permissionStatusText = "Denied"
        case .undetermined:
            permissionStatusText = "Undetermined"
        @unknown default:
            permissionStatusText = "Unknown"
        }
    }

    private func requestPermissionIfNeeded() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            updatePermissionStatusLabel()
            return true
        case .denied:
            updatePermissionStatusLabel()
            return false
        case .undetermined:
            let granted = await Self.requestRecordPermission()
            updatePermissionStatusLabel()
            return granted
        @unknown default:
            updatePermissionStatusLabel()
            return false
        }
    }

    nonisolated private static func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func configureAudioSessionIfNeeded() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    private func deactivateAudioSessionIfNeeded() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    private func configurePlaybackSessionIfNeeded() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        #endif
    }

    private func deactivatePlaybackSessionIfNeeded() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    private func beginBackgroundAssertionIfNeeded() {
        #if os(iOS)
        endBackgroundAssertionIfNeeded()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LongRecording") { [weak self] in
            self?.endBackgroundAssertionIfNeeded()
        }
        #endif
    }

    private func endBackgroundAssertionIfNeeded() {
        #if os(iOS)
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        #endif
    }

    nonisolated private static func waveformLevel(averagePower: Float, peakPower: Float) -> CGFloat {
        let minimumWaveformLevel: CGFloat = 0.01
        let normalizedAverage = normalizedPower(averagePower)
        let normalizedPeak = normalizedPower(peakPower)
        let combined = min(max((normalizedPeak * 0.72) + (normalizedAverage * 0.28), 0), 1)

        guard combined > 0.03 else {
            return minimumWaveformLevel
        }

        let boosted = pow(CGFloat(combined), 0.48)
        return min(max(boosted, minimumWaveformLevel), 1.0)
    }

    nonisolated private static func normalizedPower(_ power: Float) -> Float {
        let floor: Float = -80
        let clamped = max(power, floor)
        return (clamped - floor) / abs(floor)
    }

    nonisolated private static func duration(for url: URL) -> TimeInterval {
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            return 0
        }

        let duration = player.duration
        guard duration.isFinite, !duration.isNaN else {
            return 0
        }

        return max(0, duration)
    }

    nonisolated private static var placeholderWaveformSamples: [CGFloat] {
        Array(repeating: 0.08, count: 72)
    }

    nonisolated private static func waveformSamples(for url: URL, sampleCount: Int) -> [CGFloat] {
        guard
            let audioFile = try? AVAudioFile(forReading: url),
            audioFile.length > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(min(max(Int(audioFile.processingFormat.sampleRate / 8), 2_048), 8_192))
            )
        else {
            return placeholderWaveformSamples
        }

        let totalFrames = Int(audioFile.length)
        let framesPerBucket = max(1, Int(ceil(Double(totalFrames) / Double(sampleCount))))
        var buckets = Array(repeating: CGFloat.zero, count: sampleCount)
        var currentFrameIndex = 0

        while currentFrameIndex < totalFrames {
            do {
                try audioFile.read(into: buffer)
            } catch {
                break
            }

            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0, let channelData = buffer.floatChannelData else {
                break
            }

            let channelCount = Int(buffer.format.channelCount)
            for frame in 0..<framesRead {
                var amplitude: Float = 0
                for channel in 0..<channelCount {
                    amplitude = max(amplitude, abs(channelData[channel][frame]))
                }

                let bucketIndex = min((currentFrameIndex + frame) / framesPerBucket, sampleCount - 1)
                buckets[bucketIndex] = max(buckets[bucketIndex], CGFloat(amplitude))
            }

            currentFrameIndex += framesRead
        }

        let maxBucket = buckets.max() ?? 0
        guard maxBucket > 0 else {
            return placeholderWaveformSamples
        }

        let normalized = buckets.map { bucket in
            let scaled = min(max(bucket / maxBucket, 0), 1)
            return max(0.03, pow(scaled, 0.72))
        }

        return smoothedWaveformSamples(normalized)
    }

    nonisolated private static func smoothedWaveformSamples(_ samples: [CGFloat]) -> [CGFloat] {
        guard samples.count > 2 else {
            return samples.map { max($0, 0.03) }
        }

        return samples.enumerated().map { index, sample in
            let previous = index > 0 ? samples[index - 1] : sample
            let next = index < samples.count - 1 ? samples[index + 1] : sample
            return min(max((previous * 0.2) + (sample * 0.6) + (next * 0.2), 0.03), 1.0)
        }
    }
}

extension RecordingManager: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let recorderID = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            self?.handleRecorderEndedUnexpectedly(recorderID, errorDescription: nil)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let recorderID = ObjectIdentifier(recorder)
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleRecorderEndedUnexpectedly(recorderID, errorDescription: errorDescription)
        }
    }
}

extension RecordingManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handlePlaybackFinished(successfully: flag)
        }
    }
}
