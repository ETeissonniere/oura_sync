import SwiftUI

extension Color {
  static let paper = adaptive(light: 0xf6f5f0, dark: 0x171c1b)
  static let ink = adaptive(light: 0x203a35, dark: 0xe8eee8)
  static let secondaryInk = adaptive(light: 0x65746e, dark: 0xacb9b0)
  static let tile = adaptive(light: 0xfffefa, dark: 0x222b27)
  static let forest = adaptive(light: 0x315c4e, dark: 0xb6d1ae)
  static let softGreen = adaptive(light: 0xe6ecdf, dark: 0x313e32)

  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(
      UIColor { traits in
        let rgb = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
          red: Double((rgb >> 16) & 255) / 255,
          green: Double((rgb >> 8) & 255) / 255,
          blue: Double(rgb & 255) / 255, alpha: 1)
      })
  }
}

struct Surface<Content: View>: View {
  var prominent = false
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 16) { content }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(22)
      .background(prominent ? Color.softGreen : Color.tile, in: .rect(cornerRadius: 24))
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.medium))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 17)
      .foregroundStyle(Color.paper)
      .background(Color.forest, in: .rect(cornerRadius: 16))
      .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
  }
}

struct PageHeading: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.largeTitle.weight(.regular)).tracking(-1.3)
      Text(subtitle).font(.subheadline).foregroundStyle(Color.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 18)
  }
}

struct DetailRow: View {
  let title: String
  let value: String
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          Text(title).foregroundStyle(Color.secondaryInk)
          Text(value).fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(alignment: .firstTextBaseline) {
          Text(title)
          Spacer(minLength: 12)
          Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
      }
    }
    .font(.subheadline)
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
  }
}
