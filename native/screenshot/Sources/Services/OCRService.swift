import AppKit
import Foundation
import Vision

struct RecognizedTextResult {
    let text: String
    let observations: [VNRecognizedTextObservation]
}

final class OCRService {
    func recognize(image: NSImage, preserveLineBreaks: Bool) async throws -> RecognizedTextResult {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.coderInvalidValue)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .sorted { lhs, rhs in
                        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.025 {
                            return lhs.boundingBox.midY > rhs.boundingBox.midY
                        }
                        return lhs.boundingBox.minX < rhs.boundingBox.minX
                    }
                let strings = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: RecognizedTextResult(
                    text: strings.joined(separator: preserveLineBreaks ? "\n" : " "),
                    observations: observations
                ))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request]) }
            catch { continuation.resume(throwing: error) }
        }
    }

    @MainActor
    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
