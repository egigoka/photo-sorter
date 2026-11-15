import SwiftUI
import UIKit

// The look follows a photo editor's light table: prints in piles on a pale glowing surface,
// and a red grease pencil that marks frames on a contact sheet.

// MARK: Color

extension Color {
    /// The light table surface. Dark appearance is the table switched off.
    static let table = Color(light: 0xE9EEF0, dark: 0x1A2024)
    /// A translucent negative sleeve: panels that sit on the table.
    static let sleeve = Color(light: 0xD9E1E5, dark: 0x273036)
    /// Red grease pencil: marked photos and destructive actions.
    static let chinaRed = Color(light: 0xD9342B, dark: 0xFF5C50)
    /// Yellow grease pencil: photos to check before deciding.
    static let waxYellow = Color(light: 0xE0A400, dark: 0xFFC933)
    /// Border of a paper print. Paper stays white in both appearances.
    static let paper = Color(white: 0.985)

    private init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

// MARK: Type

enum DisplayFace {
    /// Condensed DIN, the face of film edge print and frame numbers. Ships with iOS.
    static let name = "DINCondensed-Bold"

    /// Gives navigation bars and toolbars the table surface and the display face.
    /// SwiftUI has no API for navigation title fonts.
    /// No screen uses a large navigation title: with this appearance iOS 27 does not draw it
    /// until the back swipe starts, and the swipe stalls. A screen draws its own large title.
    static func styleBars() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = UIColor(Color.table)
        navigation.shadowColor = .separator
        if let inline = UIFont(name: name, size: 22) {
            navigation.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline)]
        }
        // At the scroll edge the bar lies flat on the table, with no hairline.
        let edge = navigation.copy()
        edge.shadowColor = .clear

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = navigation
        bar.compactAppearance = navigation
        bar.scrollEdgeAppearance = edge

        let toolbar = UIToolbarAppearance()
        toolbar.configureWithOpaqueBackground()
        toolbar.backgroundColor = UIColor(Color.table)
        toolbar.shadowColor = .separator
        UIToolbar.appearance().standardAppearance = toolbar
        UIToolbar.appearance().scrollEdgeAppearance = toolbar
    }
}

extension Font {
    /// The display face at a size that follows the given text style.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom(DisplayFace.name, size: size, relativeTo: style)
    }
}

// MARK: Grease pencil

/// A loop drawn quickly around a frame: a rounded square that overshoots its own start.
/// The seed gives each loop its own wobble and tilt.
struct PencilLoop: Shape {
    var seed: Int

    func path(in rect: CGRect) -> Path {
        let phase = Double(seed % 360) * .pi / 180
        let tilt = (Double(seed / 360 % 9) - 4) * 0.014
        let start = -2.5 + Double(seed / 3240 % 5) * 0.12
        let sweep = 2 * Double.pi * 1.1
        let steps = 80
        var path = Path()
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let angle = start + sweep * progress
            // Radius shrinks along the stroke, so the end tucks inside the start.
            let radius = 1 + 0.022 * sin(2 * angle + phase) - 0.07 * progress
            let x = squared(cos(angle)) * radius
            let y = squared(sin(angle)) * radius
            let point = CGPoint(
                x: rect.midX + (x * cos(tilt) - y * sin(tilt)) * rect.width / 2,
                y: rect.midY + (x * sin(tilt) + y * cos(tilt)) * rect.height / 2
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// Pushes a circle coordinate toward a rounded square.
    private func squared(_ value: Double) -> Double {
        (value < 0 ? -1 : 1) * pow(abs(value), 0.62)
    }
}

extension String {
    /// A small number that stays the same for the same text on every launch.
    var stableSeed: Int {
        Int(unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) ^ $1.value } % 100_000)
    }
}

// MARK: Buttons

/// The main action on a screen: solid ink.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.table)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.primary, in: .rect(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.4))
    }
}

/// A secondary action: ink outline.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary, lineWidth: 1.5)
            }
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// A row that dims while pressed.
struct DimmingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}
