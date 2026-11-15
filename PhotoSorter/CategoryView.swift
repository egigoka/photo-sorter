import Photos
import SwiftUI

struct CategoryView: View {
    let category: Category
    /// Where the pile lay on the screen before. Nil when the grid opens with every photo in place.
    let origin: PileOrigin?
    /// Number of prints that lay on top of the pile. They leave it first.
    private let top: Int

    @Environment(Library.self) private var library
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.toolbarIsVertical) private var toolbarIsVertical
    @State private var assets: [PHAsset]
    @State private var selection: Set<String> = []
    @State private var loaded = false
    /// False while the top prints still lie on the pile. True once they fly to their places in the grid.
    @State private var spread: Bool
    /// False while the other photos are hidden. They come up in place when the full list is loaded.
    @State private var dealt: Bool
    /// In selection mode a tap marks a photo. Otherwise a tap opens it.
    /// Out of selection mode the selection holds the photos that the viewer marked to delete.
    @State private var selecting = false
    /// The photo open in the viewer.
    @State private var viewing: String?
    /// True when the title in the header is scrolled out of view. The bar shows the title then.
    @State private var titleInBar = false

    /// Width of the contact sheet, and the fold that crosses it.
    @State private var span = Span()
    /// The swipe that selects a run of photos. Not observed: see Sweep.
    @State private var sweep = Sweep()
    /// Moves the sheet when a swipe reaches its top or bottom edge.
    @State private var position = ScrollPosition()

    /// Smallest side of a frame. A wide sheet has larger frames, not only more of them.
    private var frameSide: CGFloat { widthClass == .regular ? 140 : 100 }

    /// Number of photos that keep their order in the pile. The rest lie under them.
    private static let ranked = 24

    /// Seconds that a print takes from the pile to its place in the grid.
    private static let flight = 0.4

    /// Name of the coordinate space of the scrolling content.
    private static let sheetSpace = "sheet"

    init(category: Category, peek: [PHAsset], origin: PileOrigin?) {
        self.category = category
        self.origin = origin
        top = peek.count
        // One-time seeds: the grid opens with the prints of the pile, and the full list replaces them.
        _assets = State(initialValue: peek)
        _spread = State(initialValue: origin == nil)
        _dealt = State(initialValue: origin == nil)
    }

    /// Changes when the category contents may have changed. Held steady during a scan,
    /// so a large grid does not reload after every batch.
    private var reloadKey: Int? {
        library.scanning ? nil : library.count(in: category)
    }

    private var allSelected: Bool {
        !assets.isEmpty && selection.count == assets.count
    }

    var body: some View {
        Group {
            if !loaded && assets.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .besideFold(span)
            } else if assets.isEmpty {
                ContentUnavailableView {
                    Label("Nothing here", systemImage: category.symbol)
                } description: {
                    Text(emptyText)
                }
                .besideFold(span)
            } else {
                let ranks = Dictionary(
                    uniqueKeysWithValues: assets.prefix(Self.ranked).enumerated().map { ($1.localIdentifier, $0) }
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        CategoryHeader(category: category, count: loaded ? assets.count : library.count(in: category))
                            .padding(.horizontal)
                            // The caution does not lie across a display that is bent.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .besideFold(span.columnsOnly)
                            .opacity(spread ? 1 : 0)
                            .animation(.easeOut(duration: 0.35), value: spread)
                        let sheet = ContactSheet(span: span, minimum: frameSide)
                        LazyVGrid(columns: sheet.columns, spacing: ContactSheet.spacing) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                cell(asset, rank: ranks[asset.localIdentifier] ?? Self.ranked)
                            }
                        }
                        .padding(.leading, sheet.inset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .coordinateSpace(.named(Self.sheetSpace))
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 44
                } action: { _, passed in
                    titleInBar = passed
                }
                .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                    sweep.scroll = geometry
                }
                // In selection mode a sideways swipe selects the photos that it crosses.
                .gesture(SidewaysPan(enabled: selecting, began: sweepBegan, moved: sweepMoved, ended: sweep.end))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Read here, not on the grid: an empty pile has no grid, and the columns depend on the result.
        .onSpanChange(horizontalFold: true) { span = $0 }
        .background(Color.table)
        .navigationTitle(barTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The middle of the bar lies on the fold of a display that folds. There the bar shows
            // the system title, which iOS puts beside the fold.
            if span.fold == nil {
                ToolbarItem(placement: .principal) {
                    if countInTopBar {
                        selectionCount
                    } else {
                        // The header shows the title. The bar takes over when the header is out of view.
                        Text(category.title)
                            .font(.display(22, relativeTo: .headline))
                            .opacity(titleInBar || assets.isEmpty ? 1 : 0)
                            .animation(.easeOut(duration: 0.15), value: titleInBar)
                            .accessibilityHidden(true)
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting {
                    Button(allSelected ? "Deselect all" : "Select all") {
                        selection = allSelected ? [] : Set(assets.map(\.localIdentifier))
                    }
                    Button("Done") {
                        selecting = false
                        selection = []
                    }
                    .fontWeight(.semibold)
                } else {
                    Button("Select") { selecting = true }
                        .disabled(assets.isEmpty)
                }
            }
            if selecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Add to album", systemImage: "rectangle.stack.badge.plus") {
                        let chosen = selectedAssets
                        Task { await library.addToAlbum(chosen, named: "Sorter – \(category.title)") }
                    }
                    .disabled(selection.isEmpty)
                    Menu("Move", systemImage: "folder") {
                        moveButtons { Array(selection) }
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    if !countInTopBar {
                        selectionCount
                        Spacer()
                    }
                    // An action with a symbol can move to a vertical bar. Text alone cannot.
                    if category.canIgnore {
                        Button("Ignore", systemImage: Category.ignored.symbol) { ignore(Array(selection)) }
                            .labelStyle(.titleAndIcon)
                            .disabled(selection.isEmpty)
                    } else if category == .ignored {
                        Button("Unignore", systemImage: "hand.raised.slash") { unignore(Array(selection)) }
                            .labelStyle(.titleAndIcon)
                            .disabled(selection.isEmpty)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        delete(selectedAssets)
                    }
                    .tint(.chinaRed)
                    .disabled(selection.isEmpty)
                }
            }
        }
        // The bar holds Done, so it stays in view while photos are selected.
        .navigationBarStays(selecting)
        .navigationDestination(item: $viewing) { start in
            PhotoViewer(category: category, assets: assets, start: start, marked: $selection) {
                remove($0)
            } reload: {
                await reload()
            }
        }
        .onChange(of: viewing) { _, shown in
            // The viewer only marks photos. They are deleted together here, so iOS asks one time.
            if shown == nil, !selecting, !selection.isEmpty { deleteMarked() }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .task(id: reloadKey) { await reload() }
    }

    private func cell(_ asset: PHAsset, rank: Int) -> some View {
        let id = asset.localIdentifier
        let selected = selection.contains(id)
        // True while the photo still lies on the pile.
        let lying = rank < top && !spread
        // True while the photo waits for the prints of the pile to leave.
        let waiting = rank >= top && !dealt
        let origin = origin
        let sweep = sweep
        // Only a print that flies out of the pile has a paper border and a shadow.
        let flies = rank < top && origin != nil
        return Button {
            if selecting { toggle(id) } else { viewing = id }
        } label: {
            ThumbnailView(asset: asset, selected: selected, side: frameSide)
                .overlay {
                    if flies { PrintEdge().opacity(lying ? 1 : 0) }
                }
                .background {
                    if flies {
                        Rectangle()
                            .fill(Color.paper)
                            .shadow(color: .black.opacity(lying ? 0.22 : 0), radius: 3, y: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.spokenName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selecting ? Text(verbatim: "") : Text("Opens the photo"))
        .contextMenu {
            Button(selected ? "Deselect" : "Select", systemImage: selected ? "circle" : "checkmark.circle") {
                selecting = true
                toggle(id)
            }
            if category.canIgnore {
                Button("Ignore", systemImage: Category.ignored.symbol) { ignore([id]) }
            } else if category == .ignored {
                Button("Unignore", systemImage: "hand.raised.slash") { unignore([id]) }
            }
            Menu("Move to", systemImage: "folder") {
                moveButtons { [id] }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                delete([asset])
            }
        } preview: {
            PreviewView(asset: asset)
        }
        // A print of the pile starts exactly where it lay on the pile that was tapped.
        .visualEffect { content, proxy in
            guard lying, let origin else {
                return content.scaleEffect(waiting ? 0.94 : 1).rotationEffect(.zero).offset(x: 0, y: 0)
            }
            let place = PileLayout.places[rank % PileLayout.places.count]
            let frame = proxy.frame(in: .global)
            return content
                .scaleEffect(origin.side * PileLayout.printScale / max(frame.width, 1))
                .rotationEffect(.degrees(place.angle))
                .offset(
                    x: origin.frame.midX - frame.midX + place.x * origin.side,
                    y: origin.frame.midY - frame.midY + place.y * origin.side
                )
        }
        .opacity(waiting ? 0 : 1)
        // The swipe that selects photos finds the photo under the finger by its frame.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.sheetSpace))
        } action: {
            sweep.frames[id] = $0
        }
        .onAppear { sweep.inView.insert(id) }
        .onDisappear { sweep.inView.remove(id) }
        // A photo that stays in view is likely to be opened. A fast scroll does not start a load.
        .task(id: id) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            ViewerPictures.prepare([asset])
        }
        // The prints of the pile fly over the other photos, the top print over all.
        .zIndex(rank < top ? Double(top - rank) : 0)
        .animation(.spring(duration: Self.flight, bounce: 0.1), value: lying)
        .animation(.easeOut(duration: 0.2).delay(Double(rank - top) * 0.005), value: waiting)
    }

    /// At regular width the top bar has room for the count. A vertical bar takes no text,
    /// so the count goes to the top bar there too.
    private var countInTopBar: Bool { selecting && (widthClass == .regular || toolbarIsVertical) }

    private var countText: String {
        selection.isEmpty ? String(localized: "Tap or swipe to select") : String(localized: "\(selection.count) selected")
    }

    /// The system title of the bar. It shows only on a display that folds: elsewhere the bar has its own title.
    private var barTitle: String {
        guard span.fold != nil else { return category.title }
        if countInTopBar { return countText }
        return titleInBar || assets.isEmpty ? category.title : ""
    }

    private var selectionCount: some View {
        Text(countText)
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(selection.isEmpty ? .secondary : .primary)
    }

    private func moveButtons(_ ids: @escaping () -> [String]) -> some View {
        ForEach(category.moveTargets) { target in
            Button(target.title, systemImage: target.symbol) {
                let moved = ids()
                library.move(moved, to: target)
                remove(moved)
            }
        }
    }

    private var selectedAssets: [PHAsset] {
        assets.filter { selection.contains($0.localIdentifier) }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func sweepBegan(at point: CGPoint) {
        sweep.begin(ids: assets.map(\.localIdentifier), selection: selection)
    }

    private func sweepMoved(to point: CGPoint) {
        if let swept = sweep.move(to: point), swept != selection { selection = swept }
        guard sweep.scroller == nil, sweep.edgeSpeed != 0 else { return }
        // The finger rests near the edge, so no more moves come. The sheet scrolls by itself.
        sweep.scroller = Task {
            var last = ContinuousClock.now
            // The scroll position counts from the start of the sheet. The loop keeps its own count:
            // the scroll view reports a move one frame late.
            var scrolled = sweep.scrolled
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = ContinuousClock.now
                guard !Task.isCancelled, let next = sweep.scrolled(from: scrolled, after: now - last) else { break }
                last = now
                scrolled = next
                position.scrollTo(y: next)
                // Other photos come under the finger.
                if let finger = sweep.finger, let swept = sweep.move(to: finger), swept != selection {
                    selection = swept
                }
            }
            if !Task.isCancelled { sweep.scroller = nil }
        }
    }

    private var emptyText: String {
        if category == .ignored { return String(localized: "Ignore a photo to keep it out of the cleanup piles.") }
        return library.sorted == 0
            ? String(localized: "Scan your library to fill this category.")
            : String(localized: "No photos are in \(category.title).")
    }

    private func ignore(_ ids: [String]) {
        library.ignore(ids)
        remove(ids)
    }

    private func unignore(_ ids: [String]) {
        library.unignore(ids)
        remove(ids)
    }

    private func delete(_ chosen: [PHAsset]) {
        Task {
            if await library.delete(chosen) { remove(chosen.map(\.localIdentifier)) }
        }
    }

    /// Deletes the photos that were marked in the viewer.
    private func deleteMarked() {
        let chosen = selectedAssets
        Task {
            if await library.delete(chosen) {
                remove(chosen.map(\.localIdentifier))
            } else {
                // The photos stay marked in selection mode, so the decision can be made in the grid.
                selecting = true
            }
        }
    }

    private func remove(_ ids: [String]) {
        let gone = Set(ids)
        withAnimation(.snappy) {
            assets.removeAll { gone.contains($0.localIdentifier) }
            selection.subtract(gone)
            if assets.isEmpty { selecting = false }
        }
    }

    private func reload() async {
        var landing: ContinuousClock.Instant?
        if !spread {
            // The prints need one frame on the pile before they can leave it.
            try? await Task.sleep(for: .milliseconds(20))
            spread = true
            landing = .now + .seconds(Self.flight * 0.7)
        }
        let fetched = await library.photos(in: category)
        // The other photos are built when the prints are almost in place, so nothing else runs
        // on the main thread while the prints fly.
        if let landing { try? await Task.sleep(until: landing) }
        guard !Task.isCancelled else { return }
        assets = fetched
        selection.formIntersection(fetched.map(\.localIdentifier))
        loaded = true
        guard !dealt else { return }
        // The photos under the top prints need one frame on the pile too.
        try? await Task.sleep(for: .milliseconds(34))
        dealt = true
    }
}

/// The white paper border of a print, drawn over the edge of a photo.
private struct PrintEdge: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Color.paper, lineWidth: 7)
            .overlay { Rectangle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

private struct CategoryHeader: View {
    let category: Category
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.display(42, relativeTo: .largeTitle))
                    .accessibilityAddTraits(.isHeader)
                Text("\(count) photos")
                    .font(.subheadline.weight(.semibold))
                // The caution says what the subtitle says, and more.
                if category.caution == nil {
                    Text(category.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let caution = category.caution {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(Color.waxYellow)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(caution)
                        .font(.footnote)
                }
                .padding(12)
                // A line of text that runs the width of a large display is hard to read.
                .frame(maxWidth: 560, alignment: .leading)
                .background(Color.sleeve, in: .rect(cornerRadius: 8, style: .continuous))
            }
        }
    }
}
