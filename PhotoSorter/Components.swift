import Photos
import SwiftUI

// MARK: Groups

extension Category {
    /// No model saw a real photo.
    static let cleanup: [Category] = [.screenshot, .meme, .graphic, .document, .misc]
    /// May hold real photos.
    static let uncertain: [Category] = [.saved]
    static let keep: [Category] = [.camera, .ignored]

    /// Pencil color of the group that the category belongs to.
    var mark: Color {
        if Category.cleanup.contains(self) { return .chinaRed }
        if Category.uncertain.contains(self) { return .waxYellow }
        return .primary.opacity(0.28)
    }

    /// Ignore is offered where a photo could still be cleaned up.
    var canIgnore: Bool { !Category.keep.contains(self) }

    /// Categories a photo can be moved to from this one. Ignored has its own action.
    var moveTargets: [Category] { Category.allCases.filter { $0 != self && $0 != .ignored } }

    var caution: String? {
        switch self {
        case .saved: "These look like photographs but carry no camera data. Some may be your own photos."
        default: nil
        }
    }
}

// MARK: Toast

struct ToastView: View {
    let text: String
    /// Takes back the edit that the banner confirms. Nil when the edit cannot be undone.
    let undo: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .padding(.vertical, 11)
            if let undo {
                Button(action: undo) {
                    Text("Undo")
                        .fontWeight(.heavy)
                        .underline()
                        .padding(.vertical, 11)
                        .padding(.horizontal, 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.table)
        .padding(.leading, 16)
        .padding(.trailing, undo == nil ? 16 : 4)
        .background(Color.primary, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Photo loading

extension PHImageRequestOptions {
    /// A quick low-quality image first when one exists, then the final image.
    static func opportunistic(network: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = network
        return options
    }
}

extension PHImageManager {
    /// Starts the image requests one after the other, away from the main thread. A request can wait
    /// for the photo library, for example after a large delete, and the screen must not wait with it.
    fileprivate static let requests = DispatchQueue(label: "me.egigoka.photosorter.image-requests", qos: .userInitiated)

    /// Delivers a quick low-quality image first when one exists, then the final image.
    func images(for asset: PHAsset, pixelSize: CGSize, contentMode: PHImageContentMode, network: Bool) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let request = RequestBox(manager: self)
            Self.requests.async {
                guard !request.isCancelled else { return }
                let options = PHImageRequestOptions.opportunistic(network: network)
                request.set(self.requestImage(for: asset, targetSize: pixelSize, contentMode: contentMode, options: options) { image, info in
                    if let image { continuation.yield(image) }
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if !degraded { continuation.finish() }
                })
            }
            continuation.onTermination = { _ in request.cancel() }
        }
    }
}

/// Small pictures that are already on the screen. A photo that moves to another view starts with
/// its picture, not with a blank frame.
@MainActor
enum LoadedPictures {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        return cache
    }()

    static subscript(id: String) -> UIImage? {
        get { cache.object(forKey: id as NSString) }
        set {
            if let newValue {
                cache.setObject(newValue, forKey: id as NSString)
            } else {
                cache.removeObject(forKey: id as NSString)
            }
        }
    }
}

/// The large pictures that the viewer shows. The grid and the viewer prepare them ahead of time,
/// so a photo is sharp as soon as it shows.
@MainActor
enum ViewerPictures {
    /// Large enough to stay sharp when zoomed, small enough to hold three pages in memory.
    private static let pixelSize = CGSize(width: 2560, height: 2560)
    /// Number of photos on each side of the shown photo that the viewer keeps prepared.
    static let reach = 50
    /// Number of photos that stay prepared: the photos around the shown photo, and one screen of the grid.
    private static let limit = 2 * reach + 1 + 24
    private static let manager = PHCachingImageManager()
    /// Prepared photos. The photo that is let go first is at the start.
    private static var prepared: [PHAsset] = []

    static func images(for asset: PHAsset) -> AsyncStream<UIImage> {
        manager.images(for: asset, pixelSize: pixelSize, contentMode: .aspectFit, network: true)
    }

    /// The file of an animated image, for the viewer to play. A file that is in iCloud is downloaded.
    /// Nil when the file cannot be read.
    static func animation(for asset: PHAsset) async -> AnimatedPicture? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        // The request starts in the continuation. A cancel that comes first has no request to stop yet.
        let request = RequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let id = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    continuation.resume(returning: data.map(AnimatedPicture.init))
                }
                request.set(id)
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// Loads the large pictures of photos before the viewer asks for them, the first photo first.
    /// A photo that is in iCloud is downloaded.
    static func prepare(_ assets: [PHAsset]) {
        let known = Set(prepared.map(\.localIdentifier))
        let new = assets.filter { !known.contains($0.localIdentifier) }
        // These photos are let go last. Of these, the first photo is let go last.
        let asked = Set(assets.map(\.localIdentifier))
        prepared.removeAll { asked.contains($0.localIdentifier) }
        prepared.append(contentsOf: assets.reversed())
        let old = Array(prepared.prefix(max(prepared.count - limit, 0)))
        prepared.removeFirst(old.count)
        guard !new.isEmpty || !old.isEmpty else { return }
        let manager = manager
        let size = pixelSize
        // Like an image request, these calls can wait for the photo library.
        PHImageManager.requests.async {
            // The same size and options as the viewer asks for. Otherwise it loads a prepared picture again.
            let options = PHImageRequestOptions.opportunistic(network: true)
            if !new.isEmpty {
                manager.startCachingImages(for: new, targetSize: size, contentMode: .aspectFit, options: options)
            }
            if !old.isEmpty {
                manager.stopCachingImages(for: old, targetSize: size, contentMode: .aspectFit, options: options)
            }
        }
    }
}

/// The file of an animated image, such as a GIF. A class: a view tells one from another without
/// a look at the bytes.
final class AnimatedPicture: Sendable {
    let data: Data

    init(data: Data) { self.data = data }
}

/// An image request that a cancelled task can stop.
private final class RequestBox: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var id: PHImageRequestID?
    private var cancelled = false

    init(manager: PHImageManager = .default()) { self.manager = manager }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func set(_ id: PHImageRequestID) {
        lock.lock()
        self.id = id
        let stop = cancelled
        lock.unlock()
        if stop { manager.cancelImageRequest(id) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = id
        lock.unlock()
        if let id { manager.cancelImageRequest(id) }
    }
}

// MARK: Contact sheet frame

/// One frame of the contact sheet. A selected frame is circled in grease pencil.
struct ThumbnailView: View {
    let asset: PHAsset
    let selected: Bool
    /// Smallest side of the frame on the sheet. The picture is loaded large enough for it.
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?

    init(asset: PHAsset, selected: Bool, side: CGFloat = 100) {
        self.asset = asset
        self.selected = selected
        self.side = side
        // A one-time seed: the picture of the print on the pile, until the sharper one is loaded.
        _image = State(initialValue: LoadedPictures[asset.localIdentifier])
    }

    var body: some View {
        Color.sleeve
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay {
                PencilMark(seed: asset.localIdentifier.stableSeed, drawn: selected ? 1 : 0)
                    .padding(9)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: selected)
            }
            .contentShape(.rect)
            .task(id: asset.localIdentifier) {
                // A frame grows to about a third more than its smallest side before one more fits in the row.
                let side = side * 1.3 * displayScale
                let stream = PHImageManager.default().images(
                    for: asset, pixelSize: CGSize(width: side, height: side), contentMode: .aspectFill, network: false
                )
                for await next in stream { image = next }
            }
    }
}

/// The red pencil loop, with a thin dark edge so it reads on a red photo too.
struct PencilMark: View {
    let seed: Int
    /// Share of the loop that is drawn, from 0 to 1.
    let drawn: Double
    /// Share of the loop where the stroke starts. Zero for a loop that is drawn from its start.
    var from = 0.0
    /// Width of the pencil stroke.
    var width: CGFloat = 5

    var body: some View {
        let loop = PencilLoop(seed: seed).trim(from: from, to: drawn)
        ZStack {
            loop.stroke(.black.opacity(0.3), style: StrokeStyle(lineWidth: width + 2, lineCap: .round, lineJoin: .round))
            loop.stroke(Color.chinaRed, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct PreviewView: View {
    let asset: PHAsset

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var size: CGSize {
        let ratio = CGFloat(max(asset.pixelWidth, 1)) / CGFloat(max(asset.pixelHeight, 1))
        let width = min(340, 520 * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    var body: some View {
        Color.sleeve
            .frame(width: size.width, height: size.height)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .task {
                let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
                let stream = PHImageManager.default().images(for: asset, pixelSize: pixels, contentMode: .aspectFit, network: true)
                for await next in stream { image = next }
            }
    }
}

// MARK: Prints

/// A paper print: a picture inside a white border.
struct PrintFrame<Picture: View>: View {
    let side: CGFloat
    @ViewBuilder let picture: Picture

    var body: some View {
        picture
            .frame(width: side, height: side)
            .clipped()
            .padding(side * 0.07)
            .background(Color.paper)
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
    }
}

/// A print of a library photo.
struct PhotoPrint: View {
    let asset: PHAsset
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    init(asset: PHAsset, side: CGFloat) {
        self.asset = asset
        self.side = side
        // A one-time seed: the picture that was loaded before, so a pile is never blank when it comes back.
        _image = State(initialValue: LoadedPictures[asset.localIdentifier])
    }

    var body: some View {
        PrintFrame(side: side) {
            Color.sleeve.overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
        }
        .task(id: asset.localIdentifier) {
            let pixels = side * displayScale
            let stream = PHImageManager.default().images(
                for: asset, pixelSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill, network: false
            )
            for await next in stream {
                image = next
                LoadedPictures[asset.localIdentifier] = next
            }
        }
    }
}

/// Where each print of a pile lies, from the top print down.
enum PileLayout {
    static let places: [(angle: Double, x: CGFloat, y: CGFloat)] = [(-3, 0, 0), (7, 0.2, -0.05), (-10, -0.2, 0.05)]

    /// Outer side of a print, relative to the side of its picture. PrintFrame adds this border.
    static let printScale: CGFloat = 1.14

    static func size(side: CGFloat) -> CGSize {
        CGSize(width: side * 1.62, height: side * 1.42)
    }
}

/// Where a pile lay on the screen when it was opened.
struct PileOrigin: Sendable {
    /// Frame of the pile, in global coordinates.
    let frame: CGRect
    /// Side of the picture of one print.
    let side: CGFloat
}

/// Up to three photos lying in a loose pile. An empty pile shows the bare spot on the table.
struct PileView: View {
    let assets: [PHAsset]
    let side: CGFloat

    var body: some View {
        let size = PileLayout.size(side: side)
        ZStack {
            if assets.isEmpty {
                Rectangle()
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: side * 1.14, height: side * 1.14)
            }
            ForEach(Array(assets.prefix(3).enumerated().reversed()), id: \.element.localIdentifier) { index, asset in
                let place = PileLayout.places[index]
                PhotoPrint(asset: asset, side: side)
                    .rotationEffect(.degrees(place.angle))
                    .offset(x: place.x * side, y: place.y * side)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}
