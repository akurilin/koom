import SwiftUI

/// A vertical scroll view that is exactly as tall as its content
/// until `maxHeight`, then scrolls. A plain ScrollView greedily fills
/// whatever height it is offered, which would defeat the main panel's
/// size-to-content window: the panel must report a finite ideal height
/// that tracks what is actually on screen.
struct HuggingScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(contentHeight, maxHeight))
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
