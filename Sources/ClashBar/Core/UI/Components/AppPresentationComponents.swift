import AppKit
import SwiftUI

private typealias T = MenuBarLayoutTokens

struct IconBadge: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: self.symbol)
            .font(.app(size: self.size * 0.5, weight: .semibold))
            .foregroundStyle(self.tint)
            .frame(width: self.size, height: self.size)
            .background(self.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct AppSectionHeader<Trailing: View>: View {
    let title: String
    var symbol: String?
    var count: String?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, symbol: String? = nil, count: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: T.space6) {
            if let symbol {
                Image(systemName: symbol).accessibilityHidden(true)
            }
            Text(self.title).lineLimit(1)
            if let count {
                Text(count)
                    .font(.appMono(size: T.FontSize.caption, weight: .medium))
                    .padding(.horizontal, T.space6)
                    .padding(.vertical, T.space2)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
            Spacer(minLength: T.space4)
            self.trailing()
        }
        .font(.app(size: T.FontSize.subheadline, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(minHeight: T.compactRowHeight)
    }
}

struct SemanticTag: View {
    let text: String
    var tint: Color = .secondary
    var monospaced = true

    var body: some View {
        Text(self.text)
            .font(self.monospaced ? .appMono(size: T.FontSize.micro, weight: .medium)
                  : .app(size: T.FontSize.caption, weight: .medium))
            .foregroundStyle(self.tint)
            .lineLimit(1)
            .minimumScaleFactor(T.minimumScale)
            .padding(.horizontal, T.space6)
            .padding(.vertical, T.space2)
            .background(self.tint.opacity(0.10), in: Capsule(style: .continuous))
    }
}

enum LatencyTier: Equatable {
    case unknown, failed, fast, moderate, slow

    init(_ value: Int?) {
        guard let value else { self = .unknown; return }
        if value <= 0 { self = .failed }
        else if value < 150 { self = .fast }
        else if value <= 350 { self = .moderate }
        else { self = .slow }
    }

    var color: Color {
        switch self {
        case .unknown: .secondary
        case .failed: Color(nsColor: .systemRed)
        case .fast:
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(red: 0.37, green: 0.86, blue: 0.54, alpha: 1)
                    : NSColor(red: 0.13, green: 0.50, blue: 0.27, alpha: 1)
            })
        case .moderate:
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(red: 0.96, green: 0.74, blue: 0.29, alpha: 1)
                    : NSColor(red: 0.65, green: 0.43, blue: 0.05, alpha: 1)
            })
        case .slow:
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(red: 1, green: 0.59, blue: 0.43, alpha: 1)
                    : NSColor(red: 0.80, green: 0.32, blue: 0.20, alpha: 1)
            })
        }
    }
}

struct LatencyPillBadge: View {
    let value: Int?
    let text: String

    var body: some View {
        let tint = LatencyTier(self.value).color
        Text(self.text)
            .font(.appMono(size: T.FontSize.caption, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(T.minimumScale)
            .padding(.horizontal, T.space6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.11), in: Capsule(style: .continuous))
    }
}

struct SheetField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: T.space6) {
            Text(self.title).font(.app(size: T.FontSize.subheadline, weight: .medium)).foregroundStyle(.secondary)
            self.content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuickToggleTile<Icon: View, Accessory: View>: View {
    let title: String
    let state: String
    let tint: Color
    let isOn: Binding<Bool>
    let disabled: Bool
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: T.space8) {
            Toggle(isOn: self.isOn) {
                VStack(alignment: .leading, spacing: T.space8) {
                    self.icon()
                    Text(self.title)
                        .font(.app(size: T.FontSize.callout, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(T.minimumScale)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch).controlSize(.mini).tint(self.tint)
            .disabled(self.disabled)
            .accessibilityLabel(self.title)
            HStack(spacing: T.space4) {
                Text(self.state).foregroundStyle(self.isOn.wrappedValue ? self.tint : .secondary)
                Spacer(minLength: 0)
                self.accessory()
            }
            .font(.app(size: T.FontSize.caption, weight: .medium))
            .lineLimit(1)
            .frame(height: 16)
        }
        .appSectionCard()
        .overlay {
            RoundedRectangle(cornerRadius: T.cardCornerRadius, style: .continuous)
                .strokeBorder(self.isOn.wrappedValue ? self.tint.opacity(0.25) : .clear, lineWidth: T.stroke)
                .allowsHitTesting(false)
        }
    }
}

struct SheetNote: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(alignment: .top, spacing: T.space6) {
            if let symbol {
                Image(systemName: symbol).frame(width: 14).accessibilityHidden(true)
            }
            Text(self.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(.app(size: T.FontSize.subheadline))
        .foregroundStyle(self.tint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModalSheetContainer<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let symbol: String
    var width: CGFloat = T.Sheet.width
    var height: CGFloat = T.Sheet.height
    var backLabel: String?
    var onBack: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: T.space10) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").frame(width: 24, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(self.backLabel ?? self.title)
                    .accessibilityLabel(self.backLabel ?? self.title)
                } else {
                    IconBadge(symbol: self.symbol, size: 32)
                }
                VStack(alignment: .leading, spacing: T.space4) {
                    Text(self.title).font(.app(size: T.FontSize.title3, weight: .semibold)).lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.app(size: T.FontSize.subheadline)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(T.space16)
            Divider()
            ScrollView {
                self.content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(T.space16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            self.footer()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(T.space16)
        }
        .font(.app(size: T.FontSize.body))
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: self.width, height: self.height)
    }
}
