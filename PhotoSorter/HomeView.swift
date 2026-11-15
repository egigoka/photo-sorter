import Photos
import SwiftUI

/// A pile that was opened, with the prints that lay on top of it.
struct PileRoute: Hashable {
    let category: Category
    let peek: [PHAsset]
    /// Where the pile lay. Nil when the grid opens without the prints flying out of the pile.
    let origin: PileOrigin?

    static func == (a: PileRoute, b: PileRoute) -> Bool { a.category == b.category }

    func hash(into hasher: inout Hasher) { hasher.combine(category) }
}

struct HomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tableIsWide) private var wide
    @State private var path: [PileRoute] = []
    /// The pile that is opening. Everything else on the table fades out around it.
    @State private var opening: Category?
    @State private var span = Span()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // A wide table has two columns. The reading order stays the same: the first column, then the second.
                TableColumns(wide: wide, fold: span.fold) {
                    VStack(alignment: .leading, spacing: 34) {
                        Summary()
                            .opacity(opening == nil ? 1 : 0)
                        ForEach(PileGroup.all.prefix(1)) { group in
                            PileSection(group: group, opening: opening, open: open)
                        }
                    }
                    VStack(alignment: .leading, spacing: 34) {
                        ForEach(PileGroup.all.dropFirst()) { group in
                            PileSection(group: group, opening: opening, open: open)
                        }
                    }
                }
                .onSpanChange { span = $0 }
                .tableMargins(wide: wide)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .background(Color.table)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ScanDock()
                    .opacity(opening == nil ? 1 : 0)
                    // The table under the dock stays opaque, so the piles do not show through it.
                    .background(Color.table)
            }
            .navigationTitle("Photo Sorter")
            // The summary sentence is the headline of this screen, so the title stays small.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ResetScanButton() }
            }
            .navigationDestination(for: PileRoute.self) { route in
                CategoryView(category: route.category, peek: route.peek, origin: route.origin)
            }
        }
    }

    /// Opens a pile. The table clears around the pile, then the grid takes over with the prints
    /// still in place, so they fly from the pile to their places in the grid.
    private func open(_ route: PileRoute) {
        guard opening == nil else { return }
        guard route.origin != nil, !reduceMotion else {
            path.append(PileRoute(category: route.category, peek: route.peek, origin: nil))
            return
        }
        withAnimation(.easeOut(duration: 0.1)) { opening = route.category }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                path.append(route)
                opening = nil
            }
        }
    }
}

// MARK: Summary

/// The state of the library in one sentence, with the share of each group below it.
private struct Summary: View {
    @Environment(Library.self) private var library

    private var cleanup: Int { Category.cleanup.reduce(0) { $0 + library.count(in: $1) } }
    private var uncertain: Int { Category.uncertain.reduce(0) { $0 + library.count(in: $1) } }
    private var keep: Int { Category.keep.reduce(0) { $0 + library.count(in: $1) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if library.sorted == 0 {
                Text("Nothing is sorted yet.")
                    .font(.display(40, relativeTo: .largeTitle))
                Text("Photo Sorter looks at every photo on this device and puts it on a pile. A photo goes to a cleanup pile only when the model sees no real photo in it.")
                    .foregroundStyle(.secondary)
            } else {
                Text(statement)
                    .font(.display(40, relativeTo: .largeTitle))
                    .contentTransition(.numericText())
                    .animation(.default, value: statement)
                ShareStrip(parts: [
                    .init(id: "cleanup", color: .chinaRed, count: cleanup),
                    .init(id: "uncertain", color: .waxYellow, count: uncertain),
                    .init(id: "keep", color: .primary.opacity(0.28), count: keep),
                ])
            }
            if library.skipped > 0 {
                Text("\(library.skipped.formatted()) skipped because they are not downloaded from iCloud. Scan again to retry.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statement: String {
        let total = library.sorted.formatted()
        switch cleanup {
        case 0: return library.sorted == 1 ? "The 1 sorted photo looks real." : "All \(total) sorted photos look real."
        case 1: return "1 of \(total) photos is not a real photo."
        default: return "\(cleanup.formatted()) of \(total) photos are not real photos."
        }
    }
}

/// A thin bar split in proportion to the given counts.
private struct ShareStrip: View {
    struct Part: Identifiable {
        let id: String
        let color: Color
        let count: Int
    }

    let parts: [Part]

    var body: some View {
        let total = CGFloat(max(parts.reduce(0) { $0 + $1.count }, 1))
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(parts.filter { $0.count > 0 }) { part in
                    Rectangle()
                        .fill(part.color)
                        .frame(width: max(3, proxy.size.width * CGFloat(part.count) / total))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
        }
        .frame(height: 6)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

// MARK: Piles

private struct PileGroup: Identifiable {
    let title: String
    /// Pencil color of the group. The same color marks its share in the summary strip.
    let mark: Color
    let note: String?
    let categories: [Category]

    var id: String { title }

    static let all = [
        PileGroup(
            title: "Clean up",
            mark: .chinaRed,
            note: "The model saw no real photo in these. Look through a pile before you delete it.",
            categories: Category.cleanup
        ),
        PileGroup(
            title: "Check first",
            mark: .waxYellow,
            note: "The model saw a photograph, but it carries no camera data. Some may be your own.",
            categories: Category.uncertain
        ),
        PileGroup(title: "Keep", mark: .primary.opacity(0.28), note: nil, categories: Category.keep),
    ]
}

private struct PileSection: View {
    let group: PileGroup
    let opening: Category?
    let open: (PileRoute) -> Void

    @ScaledMetric(relativeTo: .title2) private var dot: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(group.mark)
                        .frame(width: dot, height: dot)
                        // Lifts the dot to the middle of the capital letters.
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + dot * 0.45 }
                        .accessibilityHidden(true)
                    Text(group.title)
                        .font(.display(26, relativeTo: .title2))
                        .accessibilityAddTraits(.isHeader)
                }
                if let note = group.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(opening == nil ? 1 : 0)
            ForEach(group.categories) { category in
                PileRow(category: category, opening: opening, open: open)
            }
        }
    }
}

private struct PileRow: View {
    let category: Category
    let opening: Category?
    let open: (PileRoute) -> Void

    @Environment(Library.self) private var library
    @State private var peek: [PHAsset] = []
    /// Where the pile lies now. A plain box, so scrolling does not redraw the row.
    @State private var spot = Spot()
    @ScaledMetric(relativeTo: .body) private var printSide: CGFloat = 54

    private var count: Int { library.count(in: category) }

    /// Follows every change while idle. During a scan it settles once the pile shows three prints.
    private var reloadKey: Int { library.scanning ? min(count, 3) : count }

    var body: some View {
        let side = min(printSide, 72)
        let dimmed = opening != nil
        Button {
            let origin = peek.isEmpty ? nil : PileOrigin(frame: spot.frame, side: side)
            open(PileRoute(category: category, peek: peek, origin: origin))
        } label: {
            HStack(spacing: 14) {
                PileView(assets: peek, side: side)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { spot.frame = $0 }
                    .opacity(dimmed && opening != category ? 0 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title)
                        .font(.headline)
                    Text(category.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(dimmed ? 0 : 1)
                Text(count, format: .number)
                    .font(.display(30, relativeTo: .title))
                    .foregroundStyle(count == 0 ? .secondary : .primary)
                    .contentTransition(.numericText())
                    .animation(.default, value: count)
                    .opacity(dimmed ? 0 : 1)
            }
        }
        .buttonStyle(DimmingButtonStyle())
        .accessibilityElement(children: .combine)
        .task(id: reloadKey) {
            // The grid opens with the same three photos on top, so they are exact, not sampled.
            peek = await library.photos(in: category, limit: 3)
        }
    }
}

/// Holds the frame of a pile without telling SwiftUI about changes.
private final class Spot {
    var frame = CGRect.zero
}

// MARK: Scan dock

/// The scan action, fixed to the bottom of the table.
private struct ScanDock: View {
    @Environment(Library.self) private var library
    @Environment(\.tableIsWide) private var wide
    @State private var span = Span()

    var body: some View {
        // On a wide table the progress lies below the first column, and the button below the second.
        TableColumns(wide: wide, fold: span.fold, spacing: library.scanning ? 12 : 0) {
            VStack(alignment: .leading, spacing: 0) {
                if library.scanning {
                    ScanProgress(done: library.done, skipped: library.skipped, total: library.total, rate: library.rate)
                }
            }
            if library.scanning {
                Button("Stop", action: library.stopScan)
                    .buttonStyle(OutlineButtonStyle())
            } else {
                Button(title, action: library.startScan)
                    .buttonStyle(InkButtonStyle())
            }
        }
        .onSpanChange { span = $0 }
        .tableMargins(wide: wide)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.table)
        .overlay(alignment: .top) { Divider() }
    }

    private var title: String {
        if library.sorted == 0 { return "Scan library" }
        let remaining = library.total - library.done - library.skipped
        return remaining > 0 ? "Resume scan" : "Scan new photos"
    }
}

/// Starts the scan from the beginning, after a confirmation.
private struct ResetScanButton: View {
    @Environment(Library.self) private var library
    @State private var confirming = false

    var body: some View {
        Button("Scan all again", systemImage: "arrow.counterclockwise") { confirming = true }
            .disabled(!library.canResetScan)
            .confirmationDialog("Scan all photos again?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Scan all again", role: .destructive, action: library.resetScan)
            } message: {
                Text("Photo Sorter forgets its results and your moves between piles. Ignored photos stay ignored.")
            }
    }
}

private struct ScanProgress: View {
    let done: Int
    let skipped: Int
    let total: Int
    let rate: Double

    private var processed: Int { done + skipped }
    private var fraction: Double { total > 0 ? min(1, Double(processed) / Double(total)) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if total > 0 {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: proxy.size.width * fraction)
                        .animation(.linear(duration: 0.3), value: fraction)
                }
                .frame(height: 6)
                .background(Color.sleeve)
                .clipShape(.capsule)
                .accessibilityElement()
                .accessibilityLabel("Scan progress")
                .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
                Text("Sorting \(processed.formatted()) of \(total.formatted())")
                    .font(.headline)
                    .monospacedDigit()
                Text(pace)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Getting ready…")
                        .font(.headline)
                }
            }
            Text("Keep Photo Sorter open. Progress is saved if you stop.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var pace: String {
        guard rate > 0 else { return "Starting…" }
        let seconds = Double(total - processed) / rate
        let speed = "\(Int(rate.rounded())) photos a second"
        guard seconds >= 60 else { return "\(speed), under a minute left" }
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        let left = Duration.seconds(seconds).formatted(
            .units(allowed: units, width: .abbreviated)
        )
        return "\(speed), about \(left) left"
    }
}

// MARK: Welcome

struct WelcomeView: View {
    @Environment(Library.self) private var library
    @Environment(\.tableIsWide) private var wide
    @State private var span = Span()
    @State private var dockSpan = Span()

    var body: some View {
        ScrollView {
            // On a wide table the mark lies beside the text.
            TableColumns(wide: wide, fold: span.fold, spacing: 26) {
                CircledPile()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                VStack(alignment: .leading, spacing: 26) {
                    Text("Find everything that is not a photo.")
                        .font(.display(46, relativeTo: .largeTitle))
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Photo Sorter puts your library on piles: screenshots, memes, documents, graphics and real photos.")
                        Text("A model looks at each photo. If it sees a real photograph, the photo stays with your camera photos.")
                        Text("Everything runs on this device. No photo leaves it.")
                    }
                }
            }
            .onSpanChange { span = $0 }
            .tableMargins(wide: wide, inset: 28, narrowWidth: 520)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .background(Color.table)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // On a wide table the action lies below the text.
            TableColumns(wide: wide, fold: dockSpan.fold, spacing: 0) {
                Color.clear
                    .frame(height: 0)
                VStack(spacing: 10) {
                    if library.authorization == .notDetermined {
                        Button("Allow photo access") {
                            Task { await library.requestAccess() }
                        }
                    } else {
                        Text("Photo access is off. Turn it on in Settings to continue.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    Text("Nothing is deleted without your confirmation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(InkButtonStyle())
            }
            .onSpanChange { dockSpan = $0 }
            .tableMargins(wide: wide, inset: 28, narrowWidth: 520)
            .padding(.vertical, 12)
            .background(Color.table)
        }
    }
}

/// The mark of the app: a pile of prints with the top one circled in red pencil.
private struct CircledPile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = 0.0

    private let side: CGFloat = 132

    var body: some View {
        ZStack {
            PrintFrame(side: side) { Color.primary.opacity(0.22) }
                .rotationEffect(.degrees(-11))
                .offset(x: -34, y: 8)
            PrintFrame(side: side) { Color.waxYellow.opacity(0.75) }
                .rotationEffect(.degrees(8))
                .offset(x: 34, y: -6)
            PrintFrame(side: side) { Landscape() }
                .rotationEffect(.degrees(-2))
            PencilMark(seed: 4271, drawn: drawn)
                .frame(width: side * 1.5, height: side * 1.5)
        }
        .frame(height: side * 1.6)
        .accessibilityHidden(true)
        .task {
            guard !reduceMotion else {
                drawn = 1
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.7)) { drawn = 1 }
        }
    }
}

/// A plain picture for the top print: sky, sun, two hills.
private struct Landscape: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Color.sleeve
                Circle()
                    .fill(Color.waxYellow)
                    .frame(width: width * 0.2)
                    .position(x: width * 0.72, y: height * 0.28)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    path.addLine(to: CGPoint(x: width * 0.34, y: height * 0.46))
                    path.addLine(to: CGPoint(x: width * 0.74, y: height))
                }
                .fill(Color.primary.opacity(0.75))
                Path { path in
                    path.move(to: CGPoint(x: width * 0.36, y: height))
                    path.addLine(to: CGPoint(x: width * 0.7, y: height * 0.62))
                    path.addLine(to: CGPoint(x: width, y: height * 0.88))
                    path.addLine(to: CGPoint(x: width, y: height))
                }
                .fill(Color.primary.opacity(0.45))
            }
        }
    }
}
