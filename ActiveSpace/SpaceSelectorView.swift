import SwiftUI

/// Shown in the NSPopover when there are 3+ spaces.
/// Displays numbered bubbles; clicking one switches to that space.
///
/// When `rowWidth >= 2` and `totalSpaces > rowWidth`, the bubbles wrap into
/// a grid of rows of `rowWidth` cells each. Otherwise it renders as a single
/// horizontal row (the original behaviour).
struct SpaceSelectorView: View {

    @ObservedObject var observer: SpaceObserver
    let rowWidth: Int
    let onSelect: (Int) -> Void

    private var rows: [[Int]] {
        let total = max(1, observer.totalSpaces)
        guard rowWidth >= 2, total > rowWidth else {
            return [Array(1...total)]
        }
        return stride(from: 1, through: total, by: rowWidth).map { start in
            Array(start...min(start + rowWidth - 1, total))
        }
    }

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
                        .help("Switch to Space \(index)")
                    }
                }
            }
        }
        .padding(12)
    }
}
