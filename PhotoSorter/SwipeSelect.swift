import SwiftUI
import UIKit

/// A swipe across the contact sheet that selects a run of photos: from the photo where the swipe
/// started to the photo under the finger, in the order of the sheet.
///
/// No view observes this object. It changes many times per second, and only the swipe reads it.
@MainActor
final class Sweep {
    /// Frame of each photo that the sheet has laid out, in the space of the sheet.
    var frames: [String: CGRect] = [:]
    /// The photos that the sheet shows now. Only their frames are current.
    var inView: Set<String> = []
    /// Scroll state of the sheet.
    var scroll: ScrollGeometry?
    /// Scrolls the sheet while the finger rests near its top or bottom edge.
    var scroller: Task<Void, Never>?

    /// The last place of the finger, in the space of the scroll view: the part of the sheet that no
    /// bar covers. Nil when no swipe runs.
    private(set) var finger: CGPoint?
    /// The photos of the sheet in their order, from the start of the swipe.
    private var ids: [String] = []
    private var order: [String: Int] = [:]
    /// The selection from the start of the swipe.
    private var base: Set<String> = []
    /// The photo where the swipe started.
    private var anchor: Int?
    /// True when the swipe selects photos. False when it started on a selected photo: then it deselects.
    private var adds = true

    /// Height of the band at the top and at the bottom of the sheet where the finger makes it scroll.
    private static let edge: CGFloat = 72
    /// Points per second that the sheet scrolls when the finger is at the very edge.
    private static let topSpeed: CGFloat = 1100

    func begin(ids: [String], selection: Set<String>) {
        self.ids = ids
        order = Dictionary(ids.enumerated().map { ($1, $0) }) { first, _ in first }
        base = selection
        anchor = nil
    }

    /// The selection when the finger is at a point of the scroll view. Nil when no photo is there.
    func move(to point: CGPoint) -> Set<String>? {
        finger = point
        // The scroll view lies in the safe area. Its content starts at the insets when the offset is zero.
        let offset = scroll?.contentOffset ?? .zero
        let insets = scroll?.contentInsets ?? EdgeInsets()
        let spot = CGPoint(x: point.x + offset.x + insets.leading, y: point.y + offset.y + insets.top)
        guard let id = inView.first(where: { frames[$0]?.contains(spot) == true }), let index = order[id] else {
            return nil
        }
        // A swipe that starts beside the photos takes the first photo that it reaches.
        if anchor == nil {
            anchor = index
            adds = !base.contains(id)
        }
        guard let anchor else { return nil }
        let run = ids[min(anchor, index)...max(anchor, index)]
        return adds ? base.union(run) : base.subtracting(run)
    }

    func end() {
        scroller?.cancel()
        scroller = nil
        finger = nil
        anchor = nil
        ids = []
        order = [:]
        base = []
    }

    /// Points per second that the sheet must scroll now. Negative is up. Zero when the finger is
    /// not near the top or the bottom of the sheet.
    var edgeSpeed: CGFloat {
        guard let finger, let scroll else { return 0 }
        // The space of the scroll view is the part of the sheet that no bar covers.
        let below = finger.y - (scroll.containerSize.height - Self.edge)
        let above = Self.edge - finger.y
        if below > 0 { return min(below / Self.edge, 1) * Self.topSpeed }
        if above > 0 { return -min(above / Self.edge, 1) * Self.topSpeed }
        return 0
    }

    /// Distance that the sheet is scrolled from its start now.
    var scrolled: CGFloat {
        guard let scroll else { return 0 }
        return scroll.contentOffset.y + scroll.contentInsets.top
    }

    /// Distance from the start of the sheet after it scrolled for a time at the current speed.
    /// Nil when the sheet does not move: the finger left the edge, or the sheet is at its end.
    func scrolled(from now: CGFloat, after time: Duration) -> CGFloat? {
        guard let scroll else { return nil }
        let seconds = Double(time.components.attoseconds) / 1e18 + Double(time.components.seconds)
        // The container is the part of the sheet that no bar covers.
        let last = max(0, scroll.contentSize.height - scroll.containerSize.height)
        let next = min(max(now + edgeSpeed * seconds, 0), last)
        return abs(next - now) < 0.5 ? nil : next
    }
}

/// A drag with one finger that starts sideways. A drag that starts up or down is left to the scroll view.
struct SidewaysPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    /// Gets the point where the finger went down, in the space of the view.
    let began: (CGPoint) -> Void
    /// Gets the point where the finger is.
    let moved: (CGPoint) -> Void
    let ended: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.isEnabled = enabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        if pan.isEnabled != enabled { pan.isEnabled = enabled }
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let point = context.converter.localLocation
        switch pan.state {
        case .began:
            // The drag is recognized after the finger moved some points.
            let travel = context.converter.localTranslation ?? .zero
            began(CGPoint(x: point.x - travel.x, y: point.y - travel.y))
            moved(point)
        case .changed:
            moved(point)
        case .ended, .cancelled, .failed:
            ended()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// The scroll view waits until this drag has failed, so a sideways drag never scrolls.
        /// The swipe from the screen edge that goes back keeps its own way.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && !(other is UIScreenEdgePanGestureRecognizer)
        }
    }
}
