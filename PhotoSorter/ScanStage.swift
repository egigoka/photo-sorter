import Photos
import SwiftUI

/// The scan, on the whole table: a large pile where each sorted photo lands as a print, and the red
/// pencil that draws its loop around the pile as the scan goes on.
struct ScanStage: View {
    @Environment(Library.self) private var library
    @Environment(\.tableIsWide) private var wide
    @State private var span = Span()
    /// Height of the table that the dock and the bars leave free.
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            // On a wide table the pile lies beside the numbers.
            TableColumns(wide: wide, fold: span.fold, spacing: 22) {
                // A wide table can be low, as on an iPhone on its side. The pile stays in view there.
                ScanPile(fraction: fraction, room: wide && height > 0 ? height - 100 : .infinity)
                    .padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 22) {
                    ScanReadout()
                    ScanTally()
                }
            }
            .onSpanChange { span = $0 }
            .tableMargins(wide: wide)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Color.table)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }

    /// Share of the library that is sorted. Nil while the scan gets ready.
    private var fraction: Double? {
        if library.finished { return 1 }
        guard library.total > 0 else { return nil }
        return min(1, Double(library.done + library.skipped) / Double(library.total))
    }
}

// MARK: Pile

/// A print that the scan dealt onto the pile.
private struct Dealt: Identifiable {
    /// Counts up. A later print lies on top.
    let id: Int
    let image: UIImage
    let category: Category
    let angle: Double
    let shift: CGFloat
}

/// The mark of the app at a large size. The photos that the scan sorts land on it, and the pencil
/// loop around it shows how far the scan is.
private struct ScanPile: View {
    /// Share of the library that is sorted. Nil while the scan gets ready.
    let fraction: Double?
    /// Height that the pile can use.
    let room: CGFloat

    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// The prints on top of the pile. The last print is the top one.
    @State private var dealt: [Dealt] = []
    /// True while the pencil moves along the loop, before the scan knows how many photos there are.
    @State private var hovering = false
    /// Width that the pile can use.
    @State private var width: CGFloat = 0

    private let seed = 4271

    /// Side of the picture of a print. The pile is as large as the column lets it be.
    private var side: CGFloat {
        guard width > 0 else { return 170 }
        return max(100, min(240, width * 0.52, room / 1.6))
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                // Paper is white in each appearance, so the grey print is black on it, not the text color.
                PrintFrame(side: side) { Color.black.opacity(0.22) }
                    .rotationEffect(.degrees(-11))
                    .offset(x: -side * 0.26, y: side * 0.06)
                PrintFrame(side: side) { Color.waxYellow.opacity(0.75) }
                    .rotationEffect(.degrees(8))
                    .offset(x: side * 0.26, y: -side * 0.05)
                PrintFrame(side: side) { Landscape() }
                    .rotationEffect(.degrees(-2))
                ForEach(dealt) { print in
                    PrintFrame(side: side) {
                        Color.sleeve.overlay {
                            Image(uiImage: print.image)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .rotationEffect(.degrees(print.angle))
                    .offset(x: print.shift)
                    .zIndex(Double(print.id))
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: -56).combined(with: .scale(scale: 1.16)).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                loop
                    .zIndex(.greatestFiniteMagnitude)
            }
            .frame(height: side * 1.6)
            .accessibilityElement()
            .accessibilityLabel("Scan progress")
            .accessibilityValue(Text(fraction ?? 0, format: .percent.precision(.fractionLength(0))))
            pileName
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { await deal() }
    }

    /// A thin dashed loop shows the way of the pencil. The red loop covers it as the scan goes on.
    private var loop: some View {
        ZStack {
            PencilLoop(seed: seed)
                .stroke(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            if let fraction {
                PencilMark(seed: seed, drawn: fraction, width: 6)
                    .animation(reduceMotion ? nil : .linear(duration: 0.3), value: fraction)
            } else if !reduceMotion {
                // The pencil goes along the loop and back until the scan starts.
                PencilMark(seed: seed, drawn: hovering ? 1 : 0.16, from: hovering ? 0.84 : 0, width: 6)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { hovering = true }
                    }
            }
        }
        .frame(width: side * 1.5, height: side * 1.5)
    }

    /// The pile that the top print went to.
    private var pileName: some View {
        let category = dealt.last?.category
        return HStack(spacing: 7) {
            Circle()
                .fill(category?.mark ?? .clear)
                .frame(width: 8, height: 8)
            Text(category?.title ?? " ")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityHidden(true)
    }

    /// Puts the photo that the scan sorted last on the pile, about two times each second.
    private func deal() async {
        var last: String?
        var count = 0
        while !Task.isCancelled {
            if let sorted = library.lastSorted, sorted.asset.localIdentifier != last {
                let id = sorted.asset.localIdentifier
                last = id
                // The print lands with its picture. A blank print says nothing.
                if let image = await picture(of: sorted.asset), !Task.isCancelled {
                    count += 1
                    let seed = id.stableSeed
                    let print = Dealt(
                        id: count, image: image, category: sorted.category,
                        angle: Double(seed % 15) - 7, shift: CGFloat(seed / 15 % 13) - 6
                    )
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.74)) {
                        dealt.append(print)
                        // Three prints hide the prints below them.
                        if dealt.count > 3 { dealt.removeFirst(dealt.count - 3) }
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(520))
        }
    }

    private func picture(of asset: PHAsset) async -> UIImage? {
        let pixels = side * displayScale
        let stream = PHImageManager.default().images(
            for: asset, pixelSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill, network: false
        )
        var image: UIImage?
        for await next in stream { image = next }
        return image
    }
}

// MARK: Numbers

/// How far the scan is, in words. After the scan: its result.
private struct ScanReadout: View {
    @Environment(Library.self) private var library

    private var processed: Int { library.done + library.skipped }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.display(40, relativeTo: .largeTitle))
                .contentTransition(.numericText(value: Double(processed)))
                .animation(.snappy(duration: 0.25), value: processed)
            Text(detail)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if library.finished {
            guard library.scanned > 0 else { return String(localized: "No new photos.") }
            return String(localized: "Sorted \(library.scanned) photos.")
        }
        guard library.total > 0 else { return String(localized: "Getting ready…") }
        return String(localized: "Sorting \(processed) of \(library.total)")
    }

    private var detail: String {
        if library.finished {
            guard library.skipped > 0 else { return String(localized: "Every photo is on a pile.") }
            return String(localized: "\(library.skipped) skipped because they are not downloaded from iCloud.")
        }
        guard library.total > 0 else { return String(localized: "Photo Sorter loads its models.") }
        guard library.rate > 0 else { return String(localized: "Starting…") }
        let seconds = Double(library.total - processed) / library.rate
        let pace = max(1, Int(library.rate.rounded()))
        guard seconds >= 60 else { return String(localized: "\(pace) photos a second, under a minute left") }
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        let left = Duration.seconds(seconds).formatted(.units(allowed: units, width: .abbreviated))
        return String(localized: "\(pace) photos a second, about \(left) left")
    }
}

/// The number of photos in each group of piles, as the scan fills them.
private struct ScanTally: View {
    @Environment(Library.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let groups = PileGroup.all.map { group in
            (group: group, count: group.categories.reduce(0) { $0 + library.count(in: $1) })
        }
        VStack(alignment: .leading, spacing: 12) {
            ShareStrip(parts: groups.map { .init(id: $0.group.title, color: $0.group.mark, count: $0.count) })
                .background(Color.sleeve, in: .capsule)
            // The largest text sizes put the groups one below the other.
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            layout {
                ForEach(groups, id: \.group.id) { entry in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.count, format: .number)
                            .font(.display(34, relativeTo: .title))
                            .foregroundStyle(entry.count == 0 ? .secondary : .primary)
                            .contentTransition(.numericText(value: Double(entry.count)))
                            .animation(.snappy(duration: 0.25), value: entry.count)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(entry.group.mark)
                                .frame(width: 8, height: 8)
                            Text(entry.group.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
