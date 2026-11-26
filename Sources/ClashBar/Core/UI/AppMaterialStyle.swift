import SwiftUI

enum AppSurfaceFallbackStyle {
    case material(Material)
    case color(Color)
}

struct AppMaterialSurface: View {
    let cornerRadius: CGFloat
    let fallbackStyle: AppSurfaceFallbackStyle
    let stroke: Color
    var lineWidth: CGFloat = MenuBarLayoutTokens.stroke

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)

        Group {
            switch self.fallbackStyle {
            case let .material(material):
                shape.fill(material)
            case let .color(color):
                shape.fill(color)
            }
        }
        .overlay {
            shape.stroke(self.stroke, lineWidth: self.lineWidth)
        }
    }
}

extension View {
    func appSectionCard(padding: CGFloat = MenuBarLayoutTokens.cardPadding, opaque: Bool = false) -> some View {
        modifier(AppSectionCardModifier(padding: padding, opaque: opaque))
    }

    func appCodeBlock() -> some View {
        font(.appMono(size: MenuBarLayoutTokens.FontSize.callout))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MenuBarLayoutTokens.space10)
            .background(AppCodeSurface())
    }

    @ViewBuilder
    func appBorderedButtonStyle(prominent: Bool = false) -> some View {
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

private struct AppSectionCardModifier: ViewModifier {
    let padding: CGFloat
    let opaque: Bool

    func body(content: Content) -> some View {
        content
            .padding(self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppCardSurface(opaque: self.opaque))
    }
}

struct AppCardSurface: View {
    var opaque = false
    var cornerRadius = MenuBarLayoutTokens.cardCornerRadius
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let dark = self.colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
        let fill = self.opaque || self.reduceTransparency
            ? Color(nsColor: .controlBackgroundColor)
            : Color.white.opacity(dark ? 0.055 : 0.65)

        shape.fill(fill)
            .overlay {
                shape.strokeBorder(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.065),
                                   lineWidth: MenuBarLayoutTokens.stroke)
            }
            .shadow(color: .black.opacity(dark ? 0 : 0.025), radius: 3, y: 1)
    }
}

private struct AppCodeSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: MenuBarLayoutTokens.cornerRadius, style: .continuous)
            .fill(self.colorScheme == .dark ? Color.black.opacity(0.22) : Color.black.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: MenuBarLayoutTokens.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.065), lineWidth: MenuBarLayoutTokens.stroke)
            }
    }
}

protocol TranslatingView: View {
    var appViewModel: AppViewModel { get }
}

extension TranslatingView {
    var language: AppLanguage {
        appViewModel.uiLanguage
    }

    func tr(_ key: String) -> String {
        L10n.t(key, language: self.language)
    }

    func tr(_ key: String, _ args: CVarArg...) -> String {
        L10n.t(key, language: self.language, args: args)
    }
}
