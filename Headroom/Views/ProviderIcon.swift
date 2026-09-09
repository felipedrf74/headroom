import SwiftUI

struct ProviderIcon: View {
    var provider: Provider
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = HeadroomImage.named(provider.assetName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                    Text(provider.letter)
                        .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}
