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
            // Vision can report a failure both to the completion handler and by throwing from
            // perform(_:); resume the continuation exactly once.
            let lock = NSLock()
            var resumed = false
            let resume: (Result<RecognizedTextResult, Error>) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    resume(.failure(error))
                    return
                }
                let observations = Self.readingOrder(request.results as? [VNRecognizedTextObservation] ?? [])
                let strings = observations.compactMap { $0.topCandidates(1).first?.string }
                resume(.success(RecognizedTextResult(
                    text: strings.joined(separator: preserveLineBreaks ? "\n" : " "),
                    observations: observations
                )))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request]) }
            catch { resume(.failure(error)) }
        }
    }

    /// Top-to-bottom, then left-to-right. Lines are grouped into fixed-height row buckets so
    /// the comparison is a strict weak ordering (pairwise thresholds are not transitive).
    static func readingOrder<Item>(_ items: [Item], box: (Item) -> CGRect) -> [Item] {
        let rowHeight: CGFloat = 0.025
        func row(_ item: Item) -> Int { Int((1 - box(item).midY) / rowHeight) }
        return items.sorted { lhs, rhs in
            let (left, right) = (row(lhs), row(rhs))
            if left != right { return left < right }
            return box(lhs).minX < box(rhs).minX
        }
    }

    static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        readingOrder(observations, box: \.boundingBox)
    }

    @MainActor
    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
