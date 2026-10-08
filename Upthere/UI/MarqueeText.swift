import SwiftUI

/// One line of text that, when it doesn't fit, scrolls to reveal the rest
/// (pause, glide, pause, back) instead of truncating — without changing
/// its own size. Animates only while it overflows and is on screen.
struct MarqueeText: View {
    let text: String
    let font: Font
    var color: Color = .white
    var alignment: Alignment = .leading
    /// Take only the text's own width (when it fits) instead of all that's
    /// offered, so things beside it stay close.
    var hugs = false

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private static let speed: CGFloat = 32  // points per second
    private static let fade: CGFloat = 8

    var body: some View {
        // An invisible copy gives the line its height and flexible width.
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(0)
            .frame(maxWidth: hugs ? nil : .infinity, alignment: alignment)
            .overlay {
                GeometryReader { proxy in
                    let overflow = max(0, textWidth - proxy.size.width)
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .background {
                            GeometryReader { measured in
                                Color.clear
                                    .onAppear { textWidth = measured.size.width }
                                    .onChange(of: measured.size.width) { _, width in textWidth = width }
                            }
                        }
                        .offset(x: -offset)
                        .frame(width: proxy.size.width, alignment: overflow > 0 ? .leading : alignment)
                        .mask(edgeFade(overflowing: overflow > 0))
                        .task(id: "\(text)|\(Int(overflow))") { await scroll(overflow) }
                }
            }
    }

    private func edgeFade(overflowing: Bool) -> some View {
        GeometryReader { proxy in
            let fade = min(0.2, Self.fade / max(proxy.size.width, 1))
            LinearGradient(
                stops: [
                    .init(color: overflowing && offset > 0 ? .clear : .white, location: 0),
                    .init(color: .white, location: fade),
                    .init(color: .white, location: 1 - fade),
                    .init(color: overflowing ? .clear : .white, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
        }
    }

    private func scroll(_ overflow: CGFloat) async {
        offset = 0
        guard overflow > 1 else { return }
        let travel = overflow + Self.fade
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            let duration = Double(travel / Self.speed)
            withAnimation(.linear(duration: duration)) { offset = travel }
            try? await Task.sleep(for: .seconds(duration + 1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.45)) { offset = 0 }
            try? await Task.sleep(for: .seconds(0.45))
        }
    }
}
