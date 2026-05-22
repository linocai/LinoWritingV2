import SwiftUI

public struct DotIndicator: View {
    public var color: Color = .red
    public var size: CGFloat = 6

    public init(color: Color = .red, size: CGFloat = 6) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
