import SwiftUI

struct ProviderIcon: View {
    var provider: Provider
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = provider.assetName.flatMap({ TokenroomImage.named($0) }) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                    Text(provider.monogram)
                        .font(.system(size: size * (provider.monogram.count > 1 ? 0.36 : 0.46), weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}
