import SwiftUI

// The layouts follow the space that a view gets, not the device: an iPhone on its side, an iPad
// window of any size, and both displays of a folding iPhone.

// MARK: Width

extension EnvironmentValues {
    /// True when the table has room for two columns: at regular width, and on an iPhone on its side.
    /// The largest text sizes keep one column.
    var tableIsWide: Bool {
        (horizontalSizeClass == .regular || verticalSizeClass == .compact) && !dynamicTypeSize.isAccessibilitySize
    }
}

extension View {
    /// The margins of the table. The piles and the dock below them use the same, so their columns line up.
    func tableMargins(wide: Bool, inset: CGFloat? = nil, narrowWidth: CGFloat = .infinity) -> some View {
        padding(.horizontal, inset ?? (wide ? 28 : 20))
            .frame(maxWidth: wide ? 1100 : narrowWidth)
            .frame(maxWidth: .infinity)
    }
}

// MARK: Fold

/// The vertical fold of a display that folds, in the coordinates of the view that reads it.
struct Fold: Equatable, Sendable {
    /// Left and right edge of the fold. Nil when iOS does not tell where the fold is.
    var edges: ClosedRange<CGFloat>?
    /// True while content must stay off the fold.
    var isActive: Bool

    /// The vertical fold that crosses the view of the proxy. Nil when there is none.
    static func vertical(in proxy: GeometryProxy) -> Fold? {
        guard #available(iOS 27.1, *) else { return nil }
        // A fold that is not active counts too, so columns do not jump when the display bends.
        for region in proxy.reservedRegions(kind: .division, options: .includeInactive) {
            let frame = region.frame
            // iOS can report a fold that is not active without a frame.
            if frame.height <= 0 { return Fold(edges: nil, isActive: false) }
            // A fold that lies across scrolling content needs no room.
            if frame.height > frame.width { return Fold(edges: frame.minX...frame.maxX, isActive: region.isActive) }
        }
        return nil
    }

    /// The space to keep free at the top or at the bottom of the view of the proxy, so its content
    /// stays on the larger side of a horizontal fold. Zero when no such fold crosses the view.
    static func rowsToFree(in proxy: GeometryProxy) -> (top: CGFloat, bottom: CGFloat) {
        guard #available(iOS 27.1, *) else { return (0, 0) }
        let height = proxy.size.height
        for region in proxy.reservedRegions(kind: .division, options: .includeInactive) where region.isActive {
            let frame = region.frame
            guard frame.width > frame.height, frame.minY > 0, frame.maxY < height else { continue }
            let above = frame.minY
            let below = height - frame.maxY
            return above >= below ? (0, height - above) : (height - below, 0)
        }
        return (0, 0)
    }
}

/// The width of a view, and the fold that crosses it.
struct Span: Equatable, Sendable {
    var width: CGFloat = 0
    var fold: Fold?
    /// Space to keep free at the top and at the bottom, so content stays off a horizontal fold.
    var freeTop: CGFloat = 0
    var freeBottom: CGFloat = 0

    /// The span for a view that a horizontal fold does not cross.
    var columnsOnly: Span { Span(width: width, fold: fold) }
}

extension View {
    /// Reads the width of the view and the vertical fold that crosses it.
    /// A view that does not scroll reads the horizontal fold too.
    func onSpanChange(horizontalFold: Bool = false, _ action: @escaping (Span) -> Void) -> some View {
        onGeometryChange(for: Span.self) { proxy in
            let rows = horizontalFold ? Fold.rowsToFree(in: proxy) : (0, 0)
            return Span(width: proxy.size.width, fold: Fold.vertical(in: proxy), freeTop: rows.0, freeBottom: rows.1)
        } action: {
            action($0)
        }
    }
}

// MARK: Two columns

/// Puts two views one below the other, or side by side with the gutter over the fold.
struct TableColumns: Layout {
    /// True for two columns.
    var wide: Bool
    var fold: Fold?
    /// Distance between the two views when one is below the other.
    var spacing: CGFloat = 34
    /// Distance between the two columns.
    var gutter: CGFloat = 44

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let heights = zip(subviews, columns(in: width)).map { subview, column in
            subview.sizeThatFits(ProposedViewSize(width: column.upperBound - column.lowerBound, height: nil)).height
        }
        let height = wide ? heights.max() ?? 0 : heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var top = bounds.minY
        for (subview, column) in zip(subviews, columns(in: bounds.width)) {
            let size = ProposedViewSize(width: column.upperBound - column.lowerBound, height: nil)
            subview.place(at: CGPoint(x: bounds.minX + column.lowerBound, y: top), proposal: size)
            if !wide { top += subview.sizeThatFits(size).height + spacing }
        }
    }

    /// Left and right edge of each column.
    private func columns(in width: CGFloat) -> [ClosedRange<CGFloat>] {
        guard wide else { return [0...width, 0...width] }
        var middle = width / 2
        var gap = gutter
        // The gutter lies over the fold. It grows while content must stay off the fold.
        if let edges = fold?.edges {
            let center = (edges.lowerBound + edges.upperBound) / 2
            if center > width * 0.25, center < width * 0.75 {
                middle = center
                if fold?.isActive == true { gap = max(gutter, edges.upperBound - edges.lowerBound + 32) }
            }
        }
        return [0...max(0, middle - gap / 2), min(width, middle + gap / 2)...width]
    }
}

// MARK: Contact sheet

/// The columns of a contact sheet.
struct ContactSheet {
    static let spacing: CGFloat = 2

    let columns: [GridItem]
    /// Empty space before the first column. The side of the fold with more room keeps the rest free,
    /// so the frames on both sides have one size.
    var inset: CGFloat = 0

    /// As many columns as fit. On a display that folds the number is even, so no frame lies on the fold.
    init(span: Span, minimum: CGFloat) {
        let spacing = Self.spacing
        guard let fold = span.fold, span.width > 0 else {
            columns = [GridItem(.adaptive(minimum: minimum, maximum: minimum * 2), spacing: spacing)]
            return
        }
        let fitting = Int((span.width + spacing) / (minimum + spacing))
        let count = max(2, fitting - fitting % 2)
        let half = count / 2
        guard fold.isActive, let edges = fold.edges, edges.lowerBound > 0, edges.upperBound < span.width else {
            columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
            return
        }
        // The frames keep off the fold: the space after the last column before the fold covers it.
        let gaps = spacing * CGFloat(half - 1)
        let room = min(edges.lowerBound, span.width - edges.upperBound)
        let side = max(1, ((room - gaps) / CGFloat(half)).rounded(.down))
        columns = (0..<count).map { index in
            GridItem(.fixed(side), spacing: index == half - 1 ? edges.upperBound - edges.lowerBound : spacing)
        }
        inset = max(0, edges.lowerBound - side * CGFloat(half) - gaps)
    }
}

// MARK: Content in the middle

/// Keeps a view that fills its span on the larger side of the fold, while content must stay off the fold.
private struct BesideFold: ViewModifier {
    let span: Span
    @Environment(\.layoutDirection) private var direction

    func body(content: Content) -> some View {
        content
            .padding(direction == .leftToRight ? .leading : .trailing, free.left)
            .padding(direction == .leftToRight ? .trailing : .leading, free.right)
            .padding(.top, span.freeTop)
            .padding(.bottom, span.freeBottom)
    }

    /// The space to keep free at the left and at the right.
    private var free: (left: CGFloat, right: CGFloat) {
        guard let fold = span.fold, fold.isActive, let edges = fold.edges,
              edges.upperBound > 0, edges.lowerBound < span.width
        else { return (0, 0) }
        let left = max(0, edges.lowerBound)
        let right = max(0, span.width - edges.upperBound)
        return left >= right ? (0, span.width - left) : (span.width - right, 0)
    }
}

/// Reads the fold for a view that no parent measures.
private struct BesideOwnFold: ViewModifier {
    @State private var span = Span()

    func body(content: Content) -> some View {
        content
            .modifier(BesideFold(span: span))
            .frame(maxWidth: .infinity)
            .onSpanChange { span = $0 }
    }
}

extension View {
    /// Keeps a view on the larger side of the fold in a span that a parent measured.
    /// The view must fill the width of that span.
    func besideFold(_ span: Span) -> some View {
        modifier(BesideFold(span: span))
    }

    /// Makes the view fill the width, and keeps its content on the larger side of the fold.
    func besideFold() -> some View {
        modifier(BesideOwnFold())
    }
}

// MARK: Toolbars

extension EnvironmentValues {
    /// True when iOS shows the toolbar actions in a vertical bar at the side. That bar takes no text.
    var toolbarIsVertical: Bool {
        if #available(iOS 27.1, *) { toolbarVerticalEdge != nil } else { false }
    }
}

extension View {
    /// Keeps the navigation bar in view during a scroll. On a large display iOS moves the bar away.
    @ViewBuilder
    func navigationBarStays(_ stays: Bool) -> some View {
        if #available(iOS 27.0, *) {
            toolbarMinimizationBehavior(stays ? .never : .automatic, for: .navigationBar)
        } else {
            self
        }
    }
}
