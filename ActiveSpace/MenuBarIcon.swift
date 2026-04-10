import AppKit

/// Renders the filled-bubble menu-bar icon for a given space number.
/// Uses NSImage's drawing-handler form so colours re-evaluate on every paint,
/// automatically adapting to light / dark menu-bar appearance.
enum MenuBarIcon {

    static func image(for spaceIndex: Int) -> NSImage {
        let label = "\(spaceIndex)"
        let font  = NSFont.systemFont(ofSize: 12, weight: .semibold)

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
}
