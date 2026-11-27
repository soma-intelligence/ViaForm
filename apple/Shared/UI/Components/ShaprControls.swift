import SwiftUI

// Custom controls in the Shapr3D manner (docs/research/cad-ui/shapr3d-ipad.md): capsule buttons,
// a grey capsule track with a white sliding thumb for segmented choices, a blue pill switch, a
// rounded check box, filled grey fields with no border and pill menus with a small chevron.
// Every screen uses these instead of the platform's bordered, segmented, checkbox, switch,
// rounded-border and button-menu looks, so the Mac and the iPad draw the same controls.
//
//   Picker(.segmented)      ->  VFSegmented(selection:items:title:)
//   Picker(.menu)           ->  VFMenuPicker(selection:items:title:)
//   Toggle(.switch)         ->  .toggleStyle(.vfSwitch)
//   Toggle(.checkbox)       ->  .toggleStyle(.vfCheck)
//   Toggle(.button)         ->  .toggleStyle(.vfChip)
//   TextField(.roundedBorder) -> .vfField()
//   Menu(.button / .borderlessButton) -> .menuStyle(.vfPill) or .menuStyle(.vfPlain)
//   Button(.bordered)       ->  .buttonStyle(.vfSecondary)
//   Button(.borderless)     ->  .buttonStyle(.vfGhost)

// MARK: - Shared metrics

enum VFControl {
    /// Height of a segmented track, a field, a pill menu and a chip.
    static var height: CGFloat {
        #if os(iOS)
        36
        #else
        24
        #endif
    }
    /// Inset of the segmented thumb inside its track.
    static let thumbInset: CGFloat = 2
}

// MARK: - Segmented

/// A capsule track in the well colour with a white thumb that slides to the chosen item. Replaces
/// `Picker` with `.pickerStyle(.segmented)`. Each segment shows a title, a symbol, or both.
struct VFSegmented<Item: Hashable>: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Binding var selection: Item
    let items: [Item]
    let title: (Item) -> String
    var symbol: ((Item) -> String?)? = nil
    var label: String = ""
    @Namespace private var thumb

    init(_ label: String = "", selection: Binding<Item>, items: [Item],
         title: @escaping (Item) -> String, symbol: ((Item) -> String?)? = nil) {
        self.label = label
        self._selection = selection
        self.items = items
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                segment(item)
            }
        }
        .padding(VFControl.thumbInset)
        .frame(minHeight: VFControl.height)
        .background(Capsule(style: .continuous).fill(theme.ink.opacity(theme.isDark ? 0.10 : 0.06)))
        .overlay(theme.highContrast ? Capsule(style: .continuous).strokeBorder(theme.hairline) : nil)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ item: Item) -> some View {
        let on = item == selection
        return Button {
            guard !on else { return }
            if reduce { selection = item } else { withAnimation(.easeOut(duration: VFMotion.fast)) { selection = item } }
        } label: {
            HStack(spacing: VFSpace.xs) {
                if let s = symbol?(item) { Image(systemName: s).font(VFFont.glyph(11, weight: .semibold)) }
                let t = title(item)
                if !t.isEmpty { Text(t).lineLimit(1) }
            }
            .font(on ? VFFont.rowEmphasis : VFFont.row)
            .foregroundStyle(on ? theme.ink : theme.inkSecondary)
            .padding(.horizontal, VFSpace.m)
            .frame(maxWidth: .infinity, minHeight: VFControl.height - 2 * VFControl.thumbInset)
            .background {
                if on {
                    Capsule(style: .continuous)
                        .fill(theme.isDark ? theme.ink.opacity(0.18) : theme.panel)
                        .shadow(color: .black.opacity(theme.isDark ? 0 : 0.12), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(item))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension VFSegmented where Item: CaseIterable, Item.AllCases == [Item] {
    /// Every case of an enum, in declaration order.
    init(_ label: String = "", selection: Binding<Item>, title: @escaping (Item) -> String,
         symbol: ((Item) -> String?)? = nil) {
        self.init(label, selection: selection, items: Item.allCases, title: title, symbol: symbol)
    }
}

// MARK: - Menu picker

/// A pill showing the current choice and a small chevron; the menu marks the current item with a
/// check. Replaces `Picker` with `.pickerStyle(.menu)`.
struct VFMenuPicker<Item: Hashable>: View {
    @Binding var selection: Item
    let items: [Item]
    let title: (Item) -> String
    var label: String = ""

    init(_ label: String = "", selection: Binding<Item>, items: [Item], title: @escaping (Item) -> String) {
        self.label = label
        self._selection = selection
        self.items = items
        self.title = title
    }

    var body: some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    if item == selection { Label(title(item), systemImage: "checkmark") } else { Text(title(item)) }
                }
            }
        } label: {
            Text(title(selection)).lineLimit(1)
        }
        .menuStyle(.vfPill)
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
    }
}

// MARK: - Menu styles

/// A filled grey capsule with the label and a chevron (Shapr3D's tool mode pill).
struct VFPillMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(VFPillLabelStyle(chevron: true))
            .fixedSize()
    }
}

/// The label alone (an icon or a text), with a pointer wash; no platform border.
struct VFPlainMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(VFGhostButtonStyle())
            .fixedSize()
    }
}

extension MenuStyle where Self == VFPillMenuStyle {
    static var vfPill: VFPillMenuStyle { VFPillMenuStyle() }
}

extension MenuStyle where Self == VFPlainMenuStyle {
    static var vfPlain: VFPlainMenuStyle { VFPlainMenuStyle() }
}

/// Label of a pill menu: grey capsule, ink text, chevron.
struct VFPillLabelStyle: ButtonStyle {
    var chevron = true

    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, chevron: chevron) }

    private struct Face: View {
        @Environment(\.viaFormTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        let configuration: Configuration
        let chevron: Bool
        @State private var hovered = false

        var body: some View {
            HStack(spacing: VFSpace.xs) {
                configuration.label.lineLimit(1)
                if chevron {
                    Image(systemName: "chevron.down").font(VFFont.glyph(9, weight: .bold)).foregroundStyle(theme.inkSecondary)
                }
            }
            .fixedSize()
            .font(VFFont.row)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, VFSpace.l)
            .frame(height: VFControl.height)
            .background(Capsule(style: .continuous)
                .fill(theme.ink.opacity(configuration.isPressed ? 0.14 : hovered && enabled ? 0.10 : 0.06)))
            .overlay(theme.highContrast ? Capsule(style: .continuous).strokeBorder(theme.hairline) : nil)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
        }
    }
}

// MARK: - Ghost button

/// Text or icon with no fill until hovered or pressed: a rounded grey wash. Replaces
/// `.borderless` and `.bordered` toolbar buttons and `.link`.
struct VFGhostButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, tint: tint) }

    private struct Face: View {
        @Environment(\.viaFormTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        let configuration: Configuration
        let tint: Color?
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(tint ?? theme.ink)
                .padding(.horizontal, VFSpace.s)
                .frame(minWidth: VFSize.minTarget, minHeight: VFSize.minTarget)
                .background(RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous)
                    .fill(theme.ink.opacity(configuration.isPressed ? 0.12 : hovered && enabled ? 0.07 : 0)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous))
                .onHover { hovered = $0 }
                #if os(iOS)
                .hoverEffect(.highlight)
                #endif
        }
    }
}

extension ButtonStyle where Self == VFGhostButtonStyle {
    static var vfGhost: VFGhostButtonStyle { VFGhostButtonStyle() }
    /// Accent text, for links and "Update" in a row.
    static func vfGhost(tint: Color) -> VFGhostButtonStyle { VFGhostButtonStyle(tint: tint) }
}

// MARK: - Toggles

/// Shapr3D's switch: a capsule track, accent when on, a white knob with a soft shadow.
struct VFSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        @Environment(\.viaFormTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduce
        let configuration: Configuration

        var body: some View {
            #if os(iOS)
            let w: CGFloat = 44, h: CGFloat = 26
            #else
            let w: CGFloat = 32, h: CGFloat = 18
            #endif
            HStack(spacing: VFSpace.m) {
                configuration.label
                Spacer(minLength: VFSpace.s)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule(style: .continuous).fill(configuration.isOn ? theme.accent : theme.ink.opacity(theme.isDark ? 0.24 : 0.14))
                    Circle().fill(Color.white)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .padding(2)
                }
                .frame(width: w, height: h)
            }
            .font(VFFont.row)
            .foregroundStyle(theme.ink)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onTapGesture {
                if reduce { configuration.isOn.toggle() } else { withAnimation(.easeOut(duration: VFMotion.fast)) { configuration.isOn.toggle() } }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
            .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}

/// A rounded square that fills with the accent and a white check when on, label to its right.
struct VFCheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        @Environment(\.viaFormTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        let configuration: Configuration

        var body: some View {
            #if os(iOS)
            let side: CGFloat = 20
            #else
            let side: CGFloat = 14
            #endif
            let box = RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: VFSpace.s) {
                    ZStack {
                        box.fill(configuration.isOn ? theme.accent : theme.panel)
                        box.strokeBorder(configuration.isOn ? Color.clear : theme.ink.opacity(0.28), lineWidth: 1)
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(VFFont.glyph(side * 0.6, weight: .bold)).foregroundStyle(theme.onAccent)
                        }
                    }
                    .frame(width: side, height: side)
                    configuration.label.font(VFFont.row).foregroundStyle(theme.ink)
                }
                .frame(minHeight: VFSize.minTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
        }
    }
}

/// A chip that reads as pressed when on: accent wash and accent text, grey wash when off.
/// Replaces `.toggleStyle(.button)`.
struct VFChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        @Environment(\.viaFormTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            let shape = Capsule(style: .continuous)
            Button { configuration.isOn.toggle() } label: {
                configuration.label
                    .font(configuration.isOn ? VFFont.rowEmphasis : VFFont.row)
                    .foregroundStyle(configuration.isOn ? theme.accentText : theme.ink)
                    .padding(.horizontal, VFSpace.l)
                    .frame(minHeight: VFControl.height)
                    .background(shape.fill(configuration.isOn ? theme.accent.opacity(0.16) : theme.ink.opacity(hovered ? 0.10 : 0.06)))
                    .overlay(theme.highContrast ? shape.strokeBorder(configuration.isOn ? theme.accent : theme.hairline) : nil)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        }
    }
}

extension ToggleStyle where Self == VFSwitchToggleStyle {
    static var vfSwitch: VFSwitchToggleStyle { VFSwitchToggleStyle() }
}

extension ToggleStyle where Self == VFCheckToggleStyle {
    static var vfCheck: VFCheckToggleStyle { VFCheckToggleStyle() }
}

extension ToggleStyle where Self == VFChipToggleStyle {
    static var vfChip: VFChipToggleStyle { VFChipToggleStyle() }
}

// MARK: - Field

/// A filled grey rounded field with no border (callers keep their own focus state).
/// Replaces `.textFieldStyle(.roundedBorder)`: write `.vfField()` on the TextField.
private struct VFFieldModifier: ViewModifier {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(VFFont.row)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, VFSpace.m)
            .frame(minHeight: VFControl.height)
            .background(shape.fill(theme.ink.opacity(theme.isDark ? 0.10 : 0.05)))
            .overlay(theme.highContrast ? shape.strokeBorder(theme.hairline, lineWidth: VFSize.hairline) : nil)
            .opacity(enabled ? 1 : 0.45)
    }
}

extension View {
    /// Shapr3D field look for a TextField or SecureField (see VFFieldModifier).
    func vfField() -> some View { modifier(VFFieldModifier()) }
}
