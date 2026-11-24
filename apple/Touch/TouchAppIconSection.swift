#if os(iOS)
import SwiftUI
import UIKit

/// UI-UX-AUDIT P3-14: the App Icon choice of the iPad browser sheet (Default lattice or
/// Graphite), with a preview of each. Hidden where the system has no alternate icons. The
/// current choice comes from `alternateIconName`; a refused change shows its reason inline.
struct TouchAppIconSection: View {
    @Environment(\.viaFormTheme) private var theme
    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var changing = false
    @State private var error: String?

    struct Choice: Identifiable {
        /// nil is the primary icon.
        let iconName: String?
        let title: LocalizedStringKey
        let preview: String
        var id: String { iconName ?? "default" }
    }

    static let choices = [
        Choice(iconName: nil, title: "Default", preview: "AppIconPreview"),
        Choice(iconName: "AppIcon-Graphite", title: "Graphite", preview: "AppIconPreview-Graphite"),
    ]

    var body: some View {
        if UIApplication.shared.supportsAlternateIcons {
            Section {
                HStack(spacing: VFSpace.xl) {
                    ForEach(Self.choices) { c in tile(c) }
                }
                .padding(.vertical, VFSpace.xs)
                if let error {
                    InlineError(error, severity: .error, dismiss: { self.error = nil })
                }
            } header: {
                Text("App Icon")
            }
            .onAppear { current = UIApplication.shared.alternateIconName }
        }
    }

    private func tile(_ c: Choice) -> some View {
        let on = c.iconName == current
        return Button { pick(c) } label: {
            VStack(spacing: VFSpace.s) {
                Image(c.preview)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .inset(by: -3)
                            .stroke(on ? theme.accent : .clear, lineWidth: 2)
                    )
                    .accessibilityHidden(true)
                HStack(spacing: VFSpace.xs) {
                    if on { Image(systemName: "checkmark").font(VFFont.glyph(11, weight: .bold)).accessibilityHidden(true) }
                    Text(c.title).font(VFFont.small)
                }
                .foregroundStyle(on ? theme.accentText : theme.ink)
            }
            .frame(minWidth: VFSize.touchTarget, minHeight: VFSize.touchTarget)
            .padding(VFSpace.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .vfDisabled(changing, reason: String(localized: "Changing the icon"))
        .accessibilityLabel(Text(c.title))
        .accessibilityHint(Text("App icon"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func pick(_ c: Choice) {
        guard c.iconName != current, !changing else { return }
        changing = true
        error = nil
        Task { @MainActor in
            do {
                try await UIApplication.shared.setAlternateIconName(c.iconName)
                current = UIApplication.shared.alternateIconName
            } catch {
                self.error = String(localized: "The icon could not be changed: \(error.localizedDescription)")
            }
            changing = false
        }
    }
}
#endif
