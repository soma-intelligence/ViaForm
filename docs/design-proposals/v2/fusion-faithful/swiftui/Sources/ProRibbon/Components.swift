import AppKit
import SwiftUI

// MARK: - Icons

/// A ribbon or tool glyph: one of our satin black 3D tool icons, or an SF Symbol drawn in
/// the same near black so both kinds sit together in one panel.
enum Glyph: Hashable {
    case tool(String)
    case symbol(String)
}

struct GlyphView: View {
    let glyph: Glyph
    var size: CGFloat = 40

    var body: some View {
        switch glyph {
        case .tool(let name):
            Image(nsImage: Assets.image(name, folder: "Icons"))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: 0x4A4A4E), Color(hex: 0x111113)],
                                   startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1.5)
                .frame(width: size, height: size)
        }
    }
}

struct ViewportImage: View {
    let name: String
    var fill = false

    var body: some View {
        Image(nsImage: Assets.image(name, folder: "Viewport"))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: fill ? .fill : .fit)
    }
}

// MARK: - Dropdowns

/// A dropdown that opens a list of commands. Built from a Button and a popover rather than
/// `Menu`, so the label keeps its exact styling and ImageRenderer can draw it.
struct DropMenu<Label: View>: View {
    let items: [DropItem]
    @ViewBuilder var label: () -> Label
    @State private var open = false

    var body: some View {
        if RenderMode.active {
            label()
        } else {
            Button { open.toggle() } label: { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                item.action()
                                open = false
                            } label: {
                                HStack(spacing: 8) {
                                    if let s = item.symbol {
                                        Image(systemName: s).frame(width: 18).foregroundStyle(VF.secondary)
                                    }
                                    Text(item.title).font(.system(size: 13))
                                    Spacer(minLength: 24)
                                    if let k = item.shortcut {
                                        Text(k).font(.system(size: 12)).foregroundStyle(VF.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HoverRowStyle())
                        }
                    }
                    .padding(6)
                    .frame(minWidth: 220)
                }
        }
    }
}

struct DropItem: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String? = nil
    var shortcut: String? = nil
    var action: () -> Void = {}
}

struct HoverRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hover ? Color.white : VF.ink)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? VF.accent : .clear))
            .onHover { hover = $0 }
    }
}

// MARK: - Buttons

/// Bordered button drawn by hand (matches the concepts and renders headless).
struct VFBordered: ButtonStyle {
    var height: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(VF.ink)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xC9C9C9), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct VFProminent: ButtonStyle {
    var height: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(VF.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Surfaces

/// The floating card look of the Mac overlays: white at 0.95, radius 8, soft shadow.
struct FloatingCard: ViewModifier {
    var radius: CGFloat = 8
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.95)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
    }
}

/// The touch surfaces use a material in the live app; ImageRenderer cannot draw materials,
/// so the render uses a near white fill of the same weight.
struct TouchGlass: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background {
                if RenderMode.active {
                    RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.92))
                } else {
                    RoundedRectangle(cornerRadius: radius).fill(.ultraThinMaterial)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
}

extension View {
    func floatingCard(radius: CGFloat = 8) -> some View { modifier(FloatingCard(radius: radius)) }
    func touchGlass(radius: CGFloat = 14) -> some View { modifier(TouchGlass(radius: radius)) }
}

/// Horizontal scroller that falls back to a clipped row inside ImageRenderer.
struct HScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if RenderMode.active {
            HStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else {
            ScrollView(.horizontal, showsIndicators: false) { content() }
        }
    }
}

struct Hairline: View {
    var vertical = false
    var color = VF.separator
    var body: some View {
        Rectangle().fill(color)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Section header used in every floating panel: 12 pt semibold caps.
struct PaneHeader: View {
    let title: String
    var disclosure = true
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            if disclosure {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 7))
                    .rotationEffect(.degrees(180))
                    .foregroundStyle(VF.ink)
            }
            Text(title).font(.system(size: 12, weight: .semibold)).kerning(0.3)
            Spacer()
            if let trailing {
                Image(systemName: trailing).font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}
