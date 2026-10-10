import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ScreenRecordingResult {
    let url: URL
    let format: RecordingFormat
    let pixelSize: CGSize
    let thumbnail: NSImage?
}

enum ScreenRecordingError: LocalizedError {
    case noDisplay
    case writerSetup
    case alreadyRecording
    case noFrames
    case writerFailure(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available for recording."
        case .writerSetup: "The video writer could not be configured."
        case .alreadyRecording: "A recording is already in progress."
        case .noFrames: "The recording ended before the display produced a video frame."
        case let .writerFailure(detail): "The video writer failed: \(detail)"
        }
    }
}

final class ScreenRecordingService: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    private let outputQueue = DispatchQueue(label: "dev.subset.screenshot.recording", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var destination: URL?
    private var requestedFormat: RecordingFormat = .mp4
    private var captureSize: CGSize = .zero
    private var terminalError: Error?
    /// Total paused time removed from the output timeline, and the host time at which the
    /// current pause began (both only touched on `outputQueue`).
    private var pausedDuration: CMTime = .zero
    private var pauseBeganAt: CMTime?
    private(set) var isPaused = false
    private(set) var isCapturing = false
    /// Called on the main actor when ScreenCaptureKit stops the stream on its own (display
    /// removed, permission revoked), so the owner can finish and report the recording.
    @MainActor var onUnexpectedStop: (() -> Void)?

    @MainActor
    func start(
        area: CGRect,
        destination: URL,
        format: RecordingFormat,
        preferences: AppPreferences
    ) async throws {
        guard !isCapturing, stream == nil else { throw ScreenRecordingError.alreadyRecording }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Quartz global coordinates start at the top-left of the primary display.
        let primaryHeight = ScreenCaptureService.primaryDisplayHeight
        guard let display = content.displays.first(where: { display in
            let cocoaFrame = CGRect(x: display.frame.minX, y: primaryHeight - display.frame.maxY, width: display.frame.width, height: display.frame.height)
            return cocoaFrame.contains(CGPoint(x: area.midX, y: area.midY))
        }) ?? content.displays.first else { throw ScreenRecordingError.noDisplay }

        // The caller passes a unique destination; never delete an existing file here.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ScreenRecordingError.writerSetup }
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) })?.backingScaleFactor ?? 2
        configuration.sourceRect = CGRect(
            x: area.minX - display.frame.minX,
            y: primaryHeight - area.maxY - display.frame.minY,
            width: area.width,
            height: area.height
        )
        configuration.width = max(2, Int(area.width * scale) / 2 * 2)
        configuration.height = max(2, Int(area.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = preferences.includeCursor
        configuration.capturesAudio = preferences.recordSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = preferences.recordMicrophone
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let nextStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let nextWriter = try AVAssetWriter(outputURL: destination, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, configuration.width * configuration.height * 4),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120
            ]
        ]
        let nextVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        nextVideoInput.expectsMediaDataInRealTime = true
        guard nextWriter.canAdd(nextVideoInput) else { throw ScreenRecordingError.writerSetup }
        nextWriter.add(nextVideoInput)

        var nextSystemInput: AVAssetWriterInput?
        if preferences.recordSystemAudio {
            let input = makeAudioInput(channels: 2)
            if nextWriter.canAdd(input) { nextWriter.add(input); nextSystemInput = input }
        }

        var nextMicrophoneInput: AVAssetWriterInput?
        if preferences.recordMicrophone, #available(macOS 15.0, *) {
            let input = makeAudioInput(channels: 1)
            if nextWriter.canAdd(input) { nextWriter.add(input); nextMicrophoneInput = input }
        }

        try nextStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if preferences.recordSystemAudio {
            try nextStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        }
        if preferences.recordMicrophone, #available(macOS 15.0, *) {
            try nextStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue)
        }

        stream = nextStream
        writer = nextWriter
        videoInput = nextVideoInput
        systemAudioInput = nextSystemInput
        microphoneInput = nextMicrophoneInput
        self.destination = destination
        requestedFormat = format
        captureSize = CGSize(width: configuration.width, height: configuration.height)
        sessionStart = nil
        terminalError = nil
        pausedDuration = .zero
        pauseBeganAt = nil
        isPaused = false
        isCapturing = true

        do {
            try await nextStream.startCapture()
        } catch {
            // Roll back so the next attempt is not rejected as "already recording".
            isCapturing = false
            nextWriter.cancelWriting()
            reset()
            throw error
        }
    }

    func stop() async throws -> ScreenRecordingResult? {
        // `stream` (not `isCapturing`) marks an active session: a stream that ScreenCaptureKit
        // stopped on its own still has a writer to cancel and an error to report.
        guard let stream, let destination else { return nil }
        // ScreenCaptureKit may emit a terminal, non-display sample while stopping.
        // Close the append gate first so that sample cannot poison the writer.
        let wasCapturing = isCapturing
        isCapturing = false
        do {
            if wasCapturing { try await stream.stopCapture() }
            return try await finish(destination: destination)
        } catch {
            reset()
            throw error
        }
    }

    private func finish(destination: URL) async throws -> ScreenRecordingResult {
        let outputURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            outputQueue.async { [weak self] in
                guard let self, let writer else {
                    continuation.resume(throwing: ScreenRecordingError.writerSetup)
                    return
                }
                if let terminalError {
                    writer.cancelWriting()
                    continuation.resume(throwing: terminalError)
                    return
                }
                guard sessionStart != nil else {
                    writer.cancelWriting()
                    continuation.resume(throwing: ScreenRecordingError.noFrames)
                    return
                }
                videoInput?.markAsFinished()
                systemAudioInput?.markAsFinished()
                microphoneInput?.markAsFinished()
                writer.finishWriting {
                    if let error = writer.error {
                        continuation.resume(throwing: ScreenRecordingError.writerFailure(Self.describe(error)))
                    }
                    else { continuation.resume(returning: destination) }
                }
            }
        }

        let finalURL: URL
        if requestedFormat == .gif {
            // The destination was chosen so this name is free; never replace an existing GIF.
            finalURL = HistoryStore.uniqueURL(
                in: outputURL.deletingLastPathComponent(),
                fileName: outputURL.deletingPathExtension().appendingPathExtension("gif").lastPathComponent
            )
            try await createGIF(from: outputURL, at: finalURL)
        } else {
            finalURL = outputURL
        }

        let thumbnail = await thumbnail(for: outputURL)
        if requestedFormat == .gif { try? FileManager.default.removeItem(at: outputURL) }
        let result = ScreenRecordingResult(url: finalURL, format: requestedFormat, pixelSize: captureSize, thumbnail: thumbnail)
        reset()
        return result
    }

    func togglePause() {
        isPaused.toggle()
        let pausing = isPaused
        // ScreenCaptureKit stamps samples with the host clock, so measure the pause on it.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        outputQueue.async { [weak self] in
            guard let self else { return }
            if pausing {
                if pauseBeganAt == nil { pauseBeganAt = now }
            } else if let began = pauseBeganAt {
                pausedDuration = CMTimeAdd(pausedDuration, CMTimeSubtract(now, began))
                pauseBeganAt = nil
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            terminalError = ScreenRecordingError.writerFailure(Self.describe(error))
            isCapturing = false
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onUnexpectedStop?() }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard isCapturing, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), let writer else { return }
        if outputType == .screen {
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                  ) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        }
        // Drop paused samples and shift later ones back by the paused time, so a pause
        // leaves no frozen gap in the output.
        guard pauseBeganAt == nil, let sampleBuffer = retimed(sampleBuffer) else { return }
        let timestamp = sampleBuffer.presentationTimeStamp
        if sessionStart == nil, outputType == .screen {
            guard writer.startWriting() else {
                terminalError = writer.error.map { ScreenRecordingError.writerFailure(Self.describe($0)) }
                    ?? ScreenRecordingError.writerSetup
                return
            }
            writer.startSession(atSourceTime: timestamp)
            sessionStart = timestamp
        }
        guard sessionStart != nil else { return }

        switch outputType {
        case .screen:
            if videoInput?.isReadyForMoreMediaData == true,
               videoInput?.append(sampleBuffer) == false {
                terminalError = writer.error.map { ScreenRecordingError.writerFailure(Self.describe($0)) }
                    ?? ScreenRecordingError.writerFailure("The video frame was rejected.")
            }
        case .audio:
            if systemAudioInput?.isReadyForMoreMediaData == true,
               systemAudioInput?.append(sampleBuffer) == false {
                terminalError = writer.error.map { ScreenRecordingError.writerFailure(Self.describe($0)) }
                    ?? ScreenRecordingError.writerFailure("The system-audio frame was rejected.")
            }
        case .microphone:
            if #available(macOS 15.0, *), microphoneInput?.isReadyForMoreMediaData == true,
               microphoneInput?.append(sampleBuffer) == false {
                terminalError = writer.error.map { ScreenRecordingError.writerFailure(Self.describe($0)) }
                    ?? ScreenRecordingError.writerFailure("The microphone frame was rejected.")
            }
        @unknown default:
            break
        }
    }

    private func retimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard pausedDuration > .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: timing.count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, pausedDuration)
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, pausedDuration)
            }
        }
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        return status == noErr ? output : nil
    }

    private func makeAudioInput(channels: Int) -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func reset() {
        stream = nil
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        destination = nil
        sessionStart = nil
        terminalError = nil
        pausedDuration = .zero
        pauseBeganAt = nil
        isPaused = false
        isCapturing = false
    }

    private static func describe(_ error: Error) -> String {
        let value = error as NSError
        if value.userInfo.isEmpty { return "\(value.domain) (\(value.code))" }
        return "\(value.domain) (\(value.code)): \(value.userInfo)"
    }

    private func thumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        return try? await NSImage(cgImage: generator.image(at: .zero).image, size: .zero)
    }

    private func createGIF(from videoURL: URL, at gifURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // At most 600 frames: long recordings get a longer interval instead of being cut off.
        let maximumFrames = 600.0
        let frameInterval = max(1.0 / 12.0, duration / maximumFrames)
        let count = min(Int(maximumFrames), max(1, Int(duration / frameInterval)))
        guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) * frameInterval, preferredTimescale: 600)
            let frame = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameInterval]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
