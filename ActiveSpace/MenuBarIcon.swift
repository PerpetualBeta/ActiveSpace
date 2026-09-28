import AppKit

/// Renders the filled-bubble menu-bar icon for a given space number.
/// Uses NSImage's drawing-handler form so colours re-evaluate on every paint,
/// automatically adapting to light / dark menu-bar appearance.
enum MenuBarIcon {

    /// The widest a named bubble's text may be before the name is cut short
    /// with an ellipsis. A status item grows to fit whatever it is given, and on
    /// a notched display macOS hides items that no longer fit rather than
    /// squeezing them, so an unbounded name could push other apps out of the
    /// menu bar. Tune it live:
    ///
    ///   defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.menuBarNameMaxWidth -float 200
    ///
    /// The default is about twenty characters of 12 pt semibold, a starting
    /// point to adjust by eye, not a measured limit.
    private static var maxTextWidth: CGFloat {
        (UserDefaults.standard.object(forKey: "ActiveSpace.menuBarNameMaxWidth") as? Double)
            .map { CGFloat($0) } ?? 160
    }

    /// `name` is nil unless the user has named this space and turned on
    /// "Show the name in the menu bar"; the bubble is then the number alone,
    /// exactly as before.
    static func image(for spaceIndex: Int, name: String? = nil) -> NSImage {
        let font  = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let label = name.map { truncated("\(spaceIndex) \u{00B7} \($0)", font: font) } ?? "\(spaceIndex)"

        // Measure with a placeholder colour — size is appearance-independent.
        let textSize = (label as NSString).size(withAttributes: [.font: font, .foregroundColor: NSColor.white])

        let hPad: CGFloat  = 7
        let vPad: CGFloat  = 3
        let height: CGFloat = textSize.height + vPad * 2
        let width: CGFloat  = max(22, textSize.width + hPad * 2)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            // Light mode: dark bubble + white text
            // Dark mode:  white bubble + dark text
            let bubbleColor = isDark ? NSColor(white: 0.85, alpha: 1.0)
                                     : NSColor(white: 0.20, alpha: 0.85)
            let textColor   = isDark ? NSColor(white: 0.10, alpha: 1.0)
                                     : NSColor.white

            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            bubbleColor.setFill()
            path.fill()

            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let tx = (rect.width  - textSize.width)  / 2
            let ty = (rect.height - textSize.height) / 2
            (label as NSString).draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)

            return true
        }

        image.isTemplate = false
        return image
    }

    /// Shortens `text` from the end, adding an ellipsis, until it fits
    /// `maxTextWidth`. Drawn with `draw(at:)`, which does not truncate by itself.
    private static func truncated(_ text: String, font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let limit = maxTextWidth
        guard (text as NSString).size(withAttributes: attrs).width > limit else { return text }
        var chars = Array(text)
        while !chars.isEmpty {
            chars.removeLast()
            let candidate = String(chars).trimmingCharacters(in: .whitespaces) + "\u{2026}"
            if (candidate as NSString).size(withAttributes: attrs).width <= limit { return candidate }
        }
        return "\u{2026}"
    }
}
