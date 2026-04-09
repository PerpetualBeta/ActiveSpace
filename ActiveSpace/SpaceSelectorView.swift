import SwiftUI

/// Shown in the NSPopover when there are 3+ spaces.
/// Displays a row of numbered bubbles; clicking one switches to that space.
struct SpaceSelectorView: View {

    @ObservedObject var observer: SpaceObserver
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(1...max(1, observer.totalSpaces), id: \.self) { index in
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
        .padding(12)
    }
}
