import Vision
import CoreGraphics

enum OCR {
    static func recognizeText(in image: CGImage) async throws -> String {
        try await recognizeText(in: image, region: nil)
    }

    /// OCR a screenshot already cropped to the writing area.
    static func recognizeDocumentText(in image: CGImage) async throws -> String {
        DocumentBody.clean(try await recognizeText(in: image, region: nil))
    }

    private static func recognizeText(in image: CGImage, region: DocumentBody.Region?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .filter { obs in
                        guard let region else { return true }
                        return DocumentBody.containsPoint(obs.boundingBox, region: region)
                    }
                    .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                cont.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
