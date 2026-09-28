import SwiftUI

/// Shown in the NSPopover when there are 3+ spaces.
/// Displays numbered bubbles; clicking one switches to that space.
///
/// When `rowWidth >= 2` and `totalSpaces > rowWidth`, the bubbles wrap into
/// a grid of rows of `rowWidth` cells each. Otherwise it renders as a single
/// horizontal row (the original behaviour).
struct SpaceSelectorView: View {

    @ObservedObject var observer: SpaceObserver
    @ObservedObject private var names = SpaceNames.shared
    let rowWidth: Int
    let onSelect: (Int) -> Void
    let onRename: (Int) -> Void

    /// The bubble under the pointer, if any. Drives the name line, which
    /// replaces the system tooltip: that one waits about a second before it
    /// appears, too slow to read names while moving along the row.
    @State private var hovered: Int?

    private func name(ofSpace index: Int) -> String? {
        observer.spaceInfo(forIndex: index).flatMap { names.name(for: $0.uuid) }
    }

    private var rows: [[Int]] {
        let total = max(1, observer.totalSpaces)
        guard rowWidth >= 2, total > rowWidth else {
            return [Array(1...total)]
        }
        return stride(from: 1, through: total, by: rowWidth).map { start in
            Array(start...min(start + rowWidth - 1, total))
        }
    }

    /// What the name line says: the hovered space, or the current one when
    /// the pointer is on no bubble.
    private var nameLine: String {
        let index = hovered ?? observer.currentSpaceIndex
        return name(ofSpace: index).map { "\(index) \u{00B7} \($0)" } ?? "Space \(index)"
    }

    private var showsNameLine: Bool { names.hasMeaningfulName }

    private static let nameLineFont = Font.system(size: 12, weight: .medium)

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 10) {
                    ForEach(rows[r], id: \.self) { index in
                        Button {
                            onSelect(index)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(index == observer.currentSpaceIndex
                                          ? Color.accentColor
                                          : Color(NSColor(white: 0.25, alpha: 0.85)))
                                    .frame(width: 32, height: 32)
                                Text("\(index)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside { hovered = index } else if hovered == index { hovered = nil }
                        }
                        // The system tooltip only where there is no name line,
                        // so a popover with no names behaves as it always did.
                        .modifier(SystemTooltip(text: showsNameLine ? nil : "Switch to Space \(index)"))
                        .accessibilityLabel(name(ofSpace: index).map { "Space \(index), \($0)" }
                                            ?? "Space \(index)")
                        .contextMenu {
                            Button("Rename Space \(index)\u{2026}") { onRename(index) }
                        }
                    }
                }
            }

            // Only once a space has a real name, so the popover of someone who
            // has named nothing looks exactly as it did.
            if showsNameLine {
                // The hidden placeholder fixes the line's height and the
                // overlay draws the text without adding its width. A popover
                // that changes size after it is shown is moved by AppKit (see
                // AppDelegate.togglePopover), so the line must never resize it,
                // whichever name is showing.
                Text(verbatim: " ")
                    .font(Self.nameLineFont)
                    .hidden()
                    .frame(maxWidth: .infinity)
                    .overlay {
                        Text(nameLine)
                            .font(Self.nameLineFont)
                            .foregroundStyle(hovered == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
            }
        }
        .padding(12)
    }
}

/// `.help` only when there is text. An empty `.help("")` is not documented to
/// mean no tooltip, so the modifier is left off entirely instead.
private struct SystemTooltip: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}
