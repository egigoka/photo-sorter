import Photos
import SwiftUI
import UIKit

/// One photo at a time, for a closer look. Swipe sideways for the next photo.
struct PhotoViewer: View {
    let category: Category
    let assets: [PHAsset]
    /// The photo shown first.
    let start: String
    /// Photos marked to delete. The grid deletes them together when the viewer closes,
    /// so iOS asks one time and not for each photo.
    @Binding var marked: Set<String>
    /// Tells the grid that photos left this category.
    let removed: ([String]) -> Void
    /// Makes the grid read the photos of the category again.
    let reload: () async -> Void

    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(idType: String.self)
    /// The photo to show once the grid drops the one taken out.
    @State private var next: String?
    /// The photo taken out last. When Undo puts it back in the list, the viewer returns to it.
    @State private var taken: String?
    /// True when the last swipe went to the photo before. The next photo then comes from that side.
    @State private var backward = false
    /// The file of the photo to share. The share sheet shows while this is set.
    @State private var shared: URL?
    /// True while the photo to share is written to a file.
    @State private var exporting = false
    /// True while the sheet with the marked photos shows.
    @State private var reviewing = false
    /// True when the sheet closes to delete the marked photos.
    @State private var deleteAfterReview = false
    /// Width of the viewer, and the fold that crosses it.
    @State private var span = Span()
    /// The photo to keep in view while the viewer changes its width.
    @State private var held: String?

    private var shownIndex: Int? {
        // The scroll position is not correct while the width changes.
        let id = held ?? position.viewID(type: String.self)
        return assets.firstIndex { $0.localIdentifier == id }
    }

    private var shown: PHAsset? { shownIndex.map { assets[$0] } }

    private var shownIsMarked: Bool {
        shown.map { marked.contains($0.localIdentifier) } ?? false
    }

    var body: some View {
        // The reader gives the space between the bars, so a zoomed photo never hides under them.
        GeometryReader { proxy in
            // The pages go from edge to edge. Paging does not line up in a scroll view that the safe area
            // makes narrower. Each page keeps its photo in the safe area.
            let sides = proxy.safeAreaInsets
            let width = proxy.size.width + sides.leading + sides.trailing
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            ZoomablePhoto(asset: asset, active: asset.localIdentifier == shown?.localIdentifier) { dismiss() }
                                // A photo does not lie across a display that is bent.
                                .besideFold(span)
                                .padding(.leading, sides.leading)
                                .padding(.trailing, sides.trailing)
                                .frame(width: width, height: proxy.size.height)
                        }
                    }
                    .scrollTargetLayout()
                    // The stack keeps the old width of the pages that are out of view, and then no page
                    // lines up. A new stack measures all pages again.
                    .id(width)
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition($position)
                .scrollIndicators(.hidden)
                // A scroll position that starts on a photo does not always reach it, so move there on appear.
                .onAppear { position.scrollTo(id: start, anchor: .leading) }
                // A window that changes its width gets new pages, and the scroll does not stay on its photo.
                // The scroll goes back to the photo that was shown before the change.
                .onChange(of: width) {
                    if held == nil { held = shown?.localIdentifier }
                }
                .task(id: width) {
                    guard let held else { return }
                    // The scroll position does not move for the photo that it has already, so the reader scrolls.
                    reader.scrollTo(held, anchor: .leading)
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    reader.scrollTo(held, anchor: .leading)
                    self.held = nil
                }
                // Scrolling before the page is gone lands on the wrong photo, so wait for the new list.
                .onChange(of: assets.map(\.localIdentifier)) { _, ids in
                    if let next {
                        position.scrollTo(id: next, anchor: .leading)
                        self.next = nil
                    } else if let taken, ids.contains(taken) {
                        position.scrollTo(id: taken, anchor: .leading)
                        self.taken = nil
                    }
                }
                .onChange(of: position.viewID(type: String.self)) { old, new in
                    // Only a move between two photos of the list sets the direction. A photo that was
                    // taken out is not in the list.
                    guard held == nil,
                          let from = assets.firstIndex(where: { $0.localIdentifier == old }),
                          let to = assets.firstIndex(where: { $0.localIdentifier == new }),
                          from != to
                    else { return }
                    backward = to < from
                }
                // A swipe that comes to rest between two photos moves on to the nearer photo.
                .onScrollPhaseChange { _, phase, context in
                    guard phase == .idle else { return }
                    let width = context.geometry.containerSize.width
                    let offset = context.geometry.contentOffset.x
                    guard width > 0 else { return }
                    let page = (offset / width).rounded()
                    guard abs(offset - page * width) > 1, assets.indices.contains(Int(page)) else { return }
                    withAnimation(reduceMotion ? nil : .default) {
                        position.scrollTo(id: assets[Int(page)].localIdentifier, anchor: .leading)
                    }
                }
                .ignoresSafeArea(.container, edges: .horizontal)
            }
        }
        .onSpanChange(horizontalFold: true) { span = $0 }
        .background(Color.table)
        // The grid is covered and does not reload by itself. Undo can put a photo back in the category.
        .task(id: library.scanning ? nil : library.count(in: category)) { await reload() }
        // Photos near the shown photo are loaded ahead, so a swipe lands on a sharp picture.
        .task(id: shown?.localIdentifier) {
            // A fast run of swipes does not start a load for each photo on the way.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let index = shownIndex else { return }
            ViewerPictures.prepare(nearby(index))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 2) {
                // The line keeps its height, so the photo does not move when the mark changes.
                Text(shownIsMarked ? "Marked to delete" : " ")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.chinaRed)
                Text(shown?.creationDate?.formatted(date: .long, time: .shortened) ?? " ")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .besideFold(span.columnsOnly)
            .padding(.vertical, 8)
            .background(Color.table)
        }
        .navigationTitle(shownIndex.map { "\(($0 + 1).formatted()) of \(assets.count.formatted())" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !marked.isEmpty {
                    Button("\(marked.count.formatted()) marked") { reviewing = true }
                        .fontWeight(.semibold)
                        .tint(.chinaRed)
                        .accessibilityHint("Shows the photos marked to delete")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                // Always in the bar: an item that comes and goes makes the bar drop the Move menu.
                Button { share() } label: {
                    if exporting {
                        ProgressView()
                    } else {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(exporting)
                Menu("Move", systemImage: "folder") {
                    ForEach(category.moveTargets) { target in
                        Button(target.title, systemImage: target.symbol) {
                            guard let id = shown?.localIdentifier else { return }
                            library.move([id], to: target)
                            takeOut(id)
                        }
                    }
                }
                Spacer()
                // An action with a symbol can move to a vertical bar. Text alone cannot.
                if category.canIgnore {
                    Button("Ignore", systemImage: Category.ignored.symbol) {
                        guard let id = shown?.localIdentifier else { return }
                        library.ignore([id])
                        takeOut(id)
                    }
                    .labelStyle(.titleAndIcon)
                } else if category == .ignored {
                    Button("Unignore", systemImage: "hand.raised.slash") {
                        guard let id = shown?.localIdentifier else { return }
                        library.unignore([id])
                        takeOut(id)
                    }
                    .labelStyle(.titleAndIcon)
                }
                if shownIsMarked {
                    Button("Keep", systemImage: "trash.slash") {
                        if let id = shown?.localIdentifier { marked.remove(id) }
                    }
                } else {
                    Button("Mark to delete", systemImage: "trash") { mark() }
                        .tint(.chinaRed)
                }
            }
        }
        .disabled(shown == nil)
        .background { ShareSheet(file: $shared) }
        .sheet(isPresented: $reviewing) {
            // The viewer closes after the sheet. Going back starts the deletion in the grid.
            if deleteAfterReview {
                deleteAfterReview = false
                dismiss()
            }
        } content: {
            MarkedPhotos(assets: assets.filter { marked.contains($0.localIdentifier) }) { id in
                reviewing = false
                position.scrollTo(id: id, anchor: .leading)
            } delete: {
                deleteAfterReview = true
                reviewing = false
            }
        }
    }

    /// The photos around a photo, nearest first. At the same distance, the photo on the side that
    /// the last swipe went to comes first.
    private func nearby(_ index: Int) -> [PHAsset] {
        let step = backward ? -1 : 1
        return (1...ViewerPictures.reach)
            .flatMap { [index + $0 * step, index - $0 * step] }
            .filter { assets.indices.contains($0) }
            .map { assets[$0] }
    }

    /// Writes the shown photo to a file, then opens the share sheet with the file.
    /// The sheet gets a finished file, so each app in the sheet can take it at once.
    private func share() {
        guard let id = shown?.localIdentifier else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                shared = try await PhotoFile.export(id)
            } catch {
                library.message = "The photo could not be shared: \(error.localizedDescription)"
            }
        }
    }

    /// Marks the shown photo to delete and moves on, in the direction of the last swipe.
    private func mark() {
        guard let index = shownIndex else { return }
        let id = assets[index].localIdentifier
        marked.insert(id)
        library.confirm("Marked 1 photo to delete") {
            marked.remove(id)
            withAnimation(reduceMotion ? nil : .default) {
                position.scrollTo(id: id, anchor: .leading)
            }
        }
        let neighbor = index + (backward ? -1 : 1)
        guard assets.indices.contains(neighbor) else { return }
        withAnimation(reduceMotion ? nil : .default) {
            position.scrollTo(id: assets[neighbor].localIdentifier, anchor: .leading)
        }
    }

    /// Drops a photo that left this category and shows its neighbor, on the side that the last
    /// swipe went to.
    private func takeOut(_ id: String) {
        let index = assets.firstIndex { $0.localIdentifier == id }
        let neighbor = index.flatMap { index in
            let after = index + 1 < assets.count ? assets[index + 1] : nil
            let before = index > 0 ? assets[index - 1] : nil
            return backward ? before ?? after : after ?? before
        }
        next = neighbor?.localIdentifier
        taken = id
        removed([id])
        if neighbor == nil { dismiss() }
    }
}

private struct ZoomablePhoto: View {
    let asset: PHAsset
    /// False once the photo is swiped away. Zoom resets then.
    let active: Bool
    /// Closes the viewer.
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    /// Distance that a drag down has pulled the photo.
    @State private var pull: CGFloat = 0

    var body: some View {
        ZoomScroll(image: image, active: active) { distance in
            pull = distance
        } released: { far in
            if far {
                close()
            } else {
                withAnimation(reduceMotion ? nil : .snappy) { pull = 0 }
            }
        }
            // The photo follows the finger and shrinks a little: letting go closes the viewer.
            .scaleEffect(1 - min(pull, 400) / 400 * 0.2)
            .offset(y: pull)
            .overlay {
                if image == nil { ProgressView() }
            }
            .accessibilityElement()
            .accessibilityLabel(asset.creationDate.map { "Photo, \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Photo")
            .accessibilityAddTraits(.isImage)
            .task(id: asset.localIdentifier) {
                for await next in ViewerPictures.images(for: asset) { image = next }
            }
    }
}

/// The photos marked to delete, for a last look before they go.
private struct MarkedPhotos: View {
    let assets: [PHAsset]
    /// Shows a photo in the viewer.
    let show: (String) -> Void
    /// Deletes the marked photos.
    let delete: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        Button { show(asset.localIdentifier) } label: {
                            ThumbnailView(asset: asset, selected: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(asset.creationDate.map { "Photo, \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Photo")
                        .accessibilityHint("Shows the photo in the viewer")
                    }
                }
            }
            .background(Color.table)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Red pencil, not ink: on the glass of a sheet the ink color turns pale.
                Button(action: delete) {
                    Text("Delete \(assets.count.formatted()) \(assets.count == 1 ? "photo" : "photos")")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.chinaRed, in: .rect(cornerRadius: 12, style: .continuous))
                }
                    .buttonStyle(DimmingButtonStyle())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.table)
            }
            .navigationTitle("Marked to delete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The file of a photo, for the share sheet.
private enum PhotoFile {
    /// Writes the photo to a temporary file. Downloads it from iCloud when necessary.
    static func export(_ id: String) async throws -> URL {
        let resources = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
            .map { PHAssetResource.assetResources(for: $0) } ?? []
        let original = resources.first { $0.type == .photo }
        // The edited photo when there is one, otherwise the original.
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto }) ?? original ?? resources.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        // An edited photo keeps the name of the original, with the file type of the edit.
        let name = URL(filePath: (original ?? resource).originalFilename).deletingPathExtension().lastPathComponent
        let type = URL(filePath: resource.originalFilename).pathExtension
        // One folder holds the shared file. The file that was shared before is removed.
        let folder = URL.temporaryDirectory.appending(path: "Shared")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name).appendingPathExtension(type)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        return file
    }
}

/// The iOS share sheet for a file. ShareLink cannot wait for a file that is written on demand:
/// apps in the sheet then get nothing.
private struct ShareSheet: UIViewControllerRepresentable {
    /// The file to share. Nil again when the sheet closes.
    @Binding var file: URL?

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard let file, host.presentedViewController == nil else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            // On iPad the sheet is a popover. It points at the Share button: the first button of the
            // bar below this view.
            let bounds = host.view.bounds
            let leftToRight = host.view.effectiveUserInterfaceLayoutDirection == .leftToRight
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: leftToRight ? bounds.minX + 32 : bounds.maxX - 32, y: bounds.maxY, width: 1, height: 1)
            popover.permittedArrowDirections = .down
        }
        sheet.completionWithItemsHandler = { _, _, _, _ in self.file = nil }
        host.present(sheet, animated: true)
    }
}

/// SwiftUI has no zooming scroll view, so this wraps UIScrollView.
private struct ZoomScroll: UIViewRepresentable {
    let image: UIImage?
    let active: Bool
    /// Gets the distance of a drag down on a photo that is not zoomed.
    let pulled: (CGFloat) -> Void
    /// Gets the end of the drag. True when the drag went far or fast enough to close the viewer.
    let released: (Bool) -> Void

    func makeUIView(context: Context) -> ZoomScrollView { ZoomScrollView() }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.pulled = pulled
        view.released = released
        view.show(image)
        if !active { view.resetZoom() }
    }
}

/// Zooms with a pinch or a double tap. At rest the photo fits the view, centered, and a drag down
/// pulls it away to close the viewer.
private final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var pulled: (CGFloat) -> Void = { _ in }
    var released: (Bool) -> Void = { _ in }

    private let imageView = UIImageView()
    private let pull = UIPanGestureRecognizer()
    private var fittedBounds = CGSize.zero

    init() {
        super.init(frame: .zero)
        delegate = self
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        pull.addTarget(self, action: #selector(pulledDown))
        pull.maximumNumberOfTouches = 1
        addGestureRecognizer(pull)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        imageView.image = image
        // A sharper copy of the same photo keeps the current zoom.
        if zoomScale == 1 { fit() }
    }

    func resetZoom() {
        if zoomScale != 1 { zoomScale = 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedBounds { fit() }
    }

    private func fit() {
        fittedBounds = bounds.size
        zoomScale = 1
        guard let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        contentSize = imageView.frame.size
        center()
        updatePan()
    }

    /// A photo that fits has nothing to pan. The pan is off then, so a drag down pulls the photo.
    private func updatePan() {
        panGestureRecognizer.isEnabled = zoomScale > 1
    }

    private func center() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = tap.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    /// The pull starts only on a photo that is not zoomed, and only for a drag that goes mostly down.
    /// A sideways drag stays with the pager.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pull else { return super.gestureRecognizerShouldBegin(recognizer) }
        let velocity = pull.velocity(in: nil)
        return zoomScale == 1 && velocity.y > abs(velocity.x)
    }

    @objc private func pulledDown(_ pan: UIPanGestureRecognizer) {
        let distance = max(0, pan.translation(in: nil).y)
        switch pan.state {
        case .began, .changed:
            pulled(distance)
        case .ended:
            // A short flick closes the viewer too.
            let flicked = pan.velocity(in: nil).y > 800 && distance > 20
            released(distance > 120 || flicked)
        case .cancelled, .failed:
            released(false)
        default:
            break
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        updatePan()
    }
}
