import CoreML
import CryptoKit
import ImageIO
import OSLog
import Photos
import UIKit
import Vision

enum Category: String, Codable, CaseIterable, Identifiable {
    case screenshot, meme, saved, graphic, document, misc, camera
    /// Set by the user, never by a scan: photos to leave alone.
    case ignored

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot: "Screenshots"
        case .meme: "Memes"
        case .saved: "Saved photos"
        case .graphic: "Art & graphics"
        case .document: "Documents"
        case .misc: "Misc non-photos"
        case .camera: "Camera photos"
        case .ignored: "Ignored"
        }
    }

    var subtitle: String {
        switch self {
        case .screenshot: "Flagged by iOS or by the model"
        case .meme: "Captions, comics, reaction images"
        case .saved: "Photographs with no camera data"
        case .graphic: "Drawings, posters, logos, wallpapers"
        case .document: "Receipts, pages, forms, tickets"
        case .misc: "Not photos, kind unclear"
        case .camera: "Camera data, or the model sees a photo"
        case .ignored: "Kept out of cleanup by you"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: "iphone"
        case .meme: "face.smiling"
        case .saved: "square.and.arrow.down"
        case .graphic: "paintpalette"
        case .document: "doc.text"
        case .misc: "square.grid.2x2"
        case .camera: "camera"
        case .ignored: "hand.raised"
        }
    }
}

struct Item: Codable {
    var category: Category
    var confidence: Float
    /// For an ignored photo: the category it had before. Unignore returns it there.
    var before: Category? = nil
    /// For an ignored photo: the time of the ignore action. Photos ignored by an older version have none.
    var ignoredAt: Date? = nil
}

/// Zero-shot image classifier: a CLIP-style image encoder scored against
/// text embeddings computed offline (Resources/labels_*.json, see tools/).
final class Classifier: @unchecked Sendable {
    enum Label: String {
        case screenshot, meme, document, graphic, photo
    }

    private struct LabelFile: Decodable {
        struct Prompt: Decodable {
            let category: String
            let embedding: [Float]
        }
        let scale: Float
        let prompts: [Prompt]
    }

    private let model: VNCoreMLModel
    private let scale: Float
    private let labels: [Label]
    private let embeddings: [[Float]]

    /// The models that vote on a photo: SigLIP 2 and Perception Encoder, both ViT-B/16. They differ in
    /// training data and loss, so the cleanup piles are safer: a photo leaves the camera pile only
    /// when both agree.
    static func loadAll() throws -> [Classifier] {
        try bundled.map { try Classifier(model: $0.model, labels: $0.labels) }
    }

    private static let bundled = [
        (model: "siglip2_b16_image", labels: "labels_siglip"),
        (model: "pe_core_b16_image", labels: "labels_pe"),
    ]

    /// A value that changes when a model or its labels change. Results from other models do not
    /// fit the piles of these models. Nil when a file cannot be read.
    static func signature() -> String? {
        var hash = SHA256()
        for (model, labels) in bundled {
            guard let modelURL = Bundle.main.url(forResource: model, withExtension: "mlmodelc"),
                  let labelsURL = Bundle.main.url(forResource: labels, withExtension: "json"),
                  let labelData = try? Data(contentsOf: labelsURL),
                  let paths = FileManager.default.subpaths(atPath: modelURL.path)
            else { return nil }
            hash.update(data: Data(model.utf8))
            hash.update(data: labelData)
            for path in paths.sorted() {
                let url = modelURL.appending(path: path)
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                guard let file = try? FileHandle(forReadingFrom: url), let size = try? file.seekToEnd() else { return nil }
                defer { try? file.close() }
                hash.update(data: Data("\(path) \(size)".utf8))
                // The weights are large. Their size and samples at regular steps tell one file from another.
                let sample: UInt64 = 1 << 16
                let steps: UInt64 = size > 16 * sample ? 16 : 1
                for step in 0..<steps {
                    try? file.seek(toOffset: size / steps * step)
                    // An empty file gives no data.
                    if let part = try? file.read(upToCount: Int(steps == 1 ? max(size, 1) : sample)) {
                        hash.update(data: part)
                    }
                }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    init(model modelName: String, labels labelsName: String) throws {
        guard let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc"),
              let labelsURL = Bundle.main.url(forResource: labelsName, withExtension: "json")
        else { throw CocoaError(.fileNoSuchFile) }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL, configuration: config))
        let file = try JSONDecoder().decode(LabelFile.self, from: Data(contentsOf: labelsURL))
        scale = file.scale
        labels = file.prompts.map { Label(rawValue: $0.category) ?? .photo }
        embeddings = file.prompts.map(\.embedding)
    }

    /// Probability per label.
    func scores(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> [Label: Float] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        guard let array = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue
        else { throw CocoaError(.featureUnsupported) }

        var vector = MLShapedArray<Float>(converting: array).scalars
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        // A dead embedding (zeros or NaN) must fail the asset, not vote.
        guard norm.isFinite, norm > 0.01 else { throw CocoaError(.coderInvalidValue) }
        vector = vector.map { $0 / norm }

        // Softmax over every prompt, then sum the probability per label.
        let logits = embeddings.map { prompt in scale * zip(prompt, vector).reduce(0) { $0 + $1.0 * $1.1 } }
        let peak = logits.max() ?? 0
        let weights = logits.map { exp($0 - peak) }
        let total = weights.reduce(0, +)
        var scores: [Label: Float] = [:]
        for (label, weight) in zip(labels, weights) { scores[label, default: 0] += weight / total }
        return scores
    }
}

enum Analyzer {
    private static let log = Logger(subsystem: "me.egigoka.photosorter", category: "analyzer")

    /// A model counts as seeing a photograph when "photo" is its top label or reaches this probability.
    private static let photoDoubt: Float = 0.3

    /// Returns nil when no local image is available for the asset.
    static func analyze(_ asset: PHAsset, classifiers: [Classifier]) -> Item? {
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            return Item(category: .screenshot, confidence: 1)
        }
        if hasCameraTraits(asset) {
            return Item(category: .camera, confidence: 1)
        }
        guard let image = thumbnail(asset), let cgImage = image.cgImage else { return nil }
        var votes: [(label: Classifier.Label, confidence: Float, photo: Float)] = []
        for classifier in classifiers {
            guard let scores = try? classifier.scores(cgImage, orientation: .init(image.imageOrientation)),
                  let best = scores.max(by: { $0.value < $1.value })
            else { return nil }
            votes.append((best.key, best.value, scores[.photo] ?? 0))
            log.debug("\(asset.localIdentifier, privacy: .public) \(best.key.rawValue, privacy: .public) \(best.value, privacy: .public) photo \(scores[.photo] ?? 0, privacy: .public)")
        }
        guard let first = votes.first else { return nil }

        let confidence = votes.map(\.confidence).min() ?? 0

        // Every model calls it a photograph: metadata decides camera or saved.
        if votes.allSatisfy({ $0.label == .photo }) {
            let camera = hasCameraEXIF(asset) ?? looksLikeCameraPhoto(asset)
            return Item(category: camera ? .camera : .saved, confidence: confidence)
        }
        // One model sees a photograph: keep it with the camera photos.
        if votes.contains(where: { $0.label == .photo || $0.photo >= photoDoubt }) {
            return Item(category: .camera, confidence: confidence)
        }
        // No model sees a photograph. The kind matters only when the models agree on it.
        guard votes.allSatisfy({ $0.label == first.label }) else {
            return Item(category: .misc, confidence: confidence)
        }
        switch first.label {
        case .screenshot: return Item(category: .screenshot, confidence: confidence)
        case .meme: return Item(category: .meme, confidence: confidence)
        case .document: return Item(category: .document, confidence: confidence)
        case .graphic: return Item(category: .graphic, confidence: confidence)
        case .photo: return Item(category: .camera, confidence: confidence)
        }
    }

    /// Capture modes and file formats that only a camera produces.
    private static func hasCameraTraits(_ asset: PHAsset) -> Bool {
        let cameraSubtypes: PHAssetMediaSubtype = [.photoLive, .photoHDR, .photoDepthEffect, .photoPanorama]
        if !asset.mediaSubtypes.intersection(cameraSubtypes).isEmpty { return true }
        return PHAssetResource.assetResources(for: asset).contains { resource in
            let type = resource.uniformTypeIdentifier.lowercased()
            return type.contains("heic") || type.contains("heif") || type.contains("raw") || type.contains("dng")
        }
    }

    /// Reads EXIF from the original file. Returns nil when the original is not on the device.
    private static func hasCameraEXIF(_ asset: PHAsset) -> Bool? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.version = .original
        var found: Bool?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            guard let data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { return }
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            found = tiff?[kCGImagePropertyTIFFMake] != nil
                || tiff?[kCGImagePropertyTIFFModel] != nil
                || exif?[kCGImagePropertyExifLensModel] != nil
                || exif?[kCGImagePropertyExifFNumber] != nil
        }
        return found
    }

    /// Fallback when EXIF is unreachable: GPS tag or camera-sized resolution.
    private static func looksLikeCameraPhoto(_ asset: PHAsset) -> Bool {
        asset.location != nil || max(asset.pixelWidth, asset.pixelHeight) >= 3000
    }

    private static func thumbnail(_ asset: PHAsset) -> UIImage? {
        for mode in [PHImageRequestOptionsDeliveryMode.highQualityFormat, .fastFormat] {
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.isNetworkAccessAllowed = false
            options.deliveryMode = mode
            options.resizeMode = .fast
            var output: UIImage?
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 384, height: 384), contentMode: .aspectFit, options: options
            ) { image, _ in output = image }
            if let output { return output }
        }
        return nil
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
