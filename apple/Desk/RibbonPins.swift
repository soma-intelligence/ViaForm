#if os(macOS)
import SwiftUI

/// Ribbon dropdown details (M-19, after Fusion): the commands each reader pins to the ribbon,
/// kept per user, and the rich tooltip each command shows.
enum RibbonPins {
    static let storageKey = "viaform.ribbon.pins"

    static func ids(_ raw: String) -> [String] { raw.split(separator: ",").map(String.init) }

    /// The stored list with `id` added (at the end) or removed.
    static func toggled(_ raw: String, _ id: String) -> String {
        var list = ids(raw)
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        return list.joined(separator: ",")
    }

    static func isPinned(_ raw: String, _ id: String) -> Bool { ids(raw).contains(id) }

    /// Pins or unpins in the given defaults (the app's own by default).
    static func toggle(_ id: String, in defaults: UserDefaults = .standard) {
        defaults.set(toggled(defaults.string(forKey: storageKey) ?? "", id), forKey: storageKey)
    }

    static func pinned(in defaults: UserDefaults = .standard) -> [String] { ids(defaults.string(forKey: storageKey) ?? "") }

    /// The tooltip: the name and key, the registry's one-line parameter summary, and where the
    /// command lives in the ribbon.
    static func tooltip(_ c: CommandInfo) -> String {
        var lines = [c.key.map { "\(StageLabels.command(c.label)) (\(DeskKeymap.glyph($0)))" } ?? StageLabels.command(c.label)]
        let summary = c.params.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { lines.append(summary) }
        let place = [c.tab, c.panel].filter { !$0.isEmpty }.map { StageLabels.panel($0).capitalized }.joined(separator: " · ")
        if !place.isEmpty { lines.append(place) }
        return lines.joined(separator: "\n")
    }

    /// The key printed at the right of a dropdown row when the menu cannot bind it as a key
    /// equivalent (anything but a single letter).
    static func rowKey(_ key: String?) -> String? {
        guard let key, RibbonPanelView.menuKey(key) == nil else { return nil }
        return DeskKeymap.glyph(key)
    }
}

/// The reader's pinned commands, as a panel of big icons at the head of the design ribbon.
struct PinnedPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @AppStorage(RibbonPins.storageKey) private var pins = ""

    private var commands: [CommandInfo] {
        RibbonPins.ids(pins).compactMap { id in model.commands.first { $0.id == id } }
    }

    var body: some View {
        let list = commands
        if !list.isEmpty {
            HStack(alignment: .top, spacing: VFSpace.xs) {
                VStack(spacing: 1) {
                    HStack(spacing: VFSpace.xxs) {
                        ForEach(list) { c in
                            Button { CommandRouter.run(c, model) } label: {
                                ToolChipIcon(icon: c.icon, id: c.id, size: 22)
                                    .frame(width: 36, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(RibbonPins.tooltip(c))
                            .accessibilityLabel(StageLabels.command(c.label))
                            .contextMenu {
                                Button("Unpin from Toolbar") { pins = RibbonPins.toggled(pins, c.id) }
                            }
                        }
                    }
                    VFCaption("Pinned")
                }
                .padding(.horizontal, VFSpace.xs)
                VFHairline(vertical: true).frame(height: 42)
            }
            .fixedSize()
        }
    }
}
#endif
