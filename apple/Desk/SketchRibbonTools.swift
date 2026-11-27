#if os(macOS)
import SwiftUI

/// The sketch tab's CREATE and MODIFY panels with every click-to-draw tool (B-11): the registry's
/// own entries first, then the tools of `Tool.moreSketchTools` the registry does not list, in the
/// reference's order. Extend sits in MODIFY next to Trim; Project, Mirror, the patterns and the
/// extra rectangle, circle and ellipse kinds sit in CREATE. A registry entry keeps its panel and
/// key; a missing one gets the tool's own name and symbol and no key.
@MainActor
enum SketchRibbonTools {
    static let createPanel = "CREATE"
    static let modifyPanel = "MODIFY"

    /// The panel a sketch tool belongs in, as in the reference's menus.
    static func panel(of tool: Tool) -> String { tool == .extend ? modifyPanel : createPanel }

    /// The sketch tab's panels with the extra tools merged in. Other tabs come back unchanged.
    static func merge(_ panels: [RibbonPanelModel], commands: [CommandInfo]) -> [RibbonPanelModel] {
        var out = panels
        for tool in Tool.moreSketchTools {
            guard let id = tool.commandID else { continue }
            // The reference's panel wins over the registry's (Mirror and the patterns in CREATE).
            let listed = out.flatMap(\.commands).first { $0.id == id }
            out = out.map { RibbonPanelModel(name: $0.name, commands: $0.commands.filter { $0.id != id }) }.filter { !$0.commands.isEmpty }
            let registry = listed ?? commands.first { $0.id == id }
            let info = CommandInfo(id: id, label: registry?.label ?? tool.label, tab: "SKETCH",
                                   panel: panel(of: tool), icon: registry?.icon ?? id, key: registry?.key, params: registry?.params ?? "")
            let name = panelName(panel(of: tool), in: out)
            if let i = out.firstIndex(where: { $0.name == name }) {
                out[i] = RibbonPanelModel(name: name, commands: out[i].commands + [info])
            } else {
                out.append(RibbonPanelModel(name: name, commands: [info]))
            }
        }
        return out.map(ordered)
    }

    // MARK: Fusion order

    /// One line of a sketch dropdown: a command, or a submenu ("Rectangle >").
    enum MenuEntry: Identifiable {
        case command(CommandInfo)
        case submenu(String, [CommandInfo])

        var id: String {
            switch self {
            case .command(let c): c.id
            case .submenu(let t, _): "menu." + t
            }
        }
        var commands: [CommandInfo] {
            switch self {
            case .command(let c): [c]
            case .submenu(_, let cs): cs
            }
        }
    }

    /// A slot of the reference dropdown: its ids in order, then any other id under `prefix`.
    /// A titled slot with more than one command becomes a submenu.
    private struct Slot {
        var title: String?
        var ids: [String]
        var prefix: String?
    }

    /// The sketch CREATE dropdown in the reference's order (fusion-desktop.md 2.8).
    private static let createSlots: [Slot] = [
        Slot(ids: ["sketch.line"]),
        Slot(title: String(localized: "Rectangle"), ids: ["sketch.rectangle.two_point", "sketch.rectangle.three_point", "sketch.rectangle.center"], prefix: "sketch.rectangle."),
        Slot(title: String(localized: "Circle"), ids: ["sketch.circle.center", "sketch.circle.two_point", "sketch.circle.three_point",
                                                         "sketch.circle.two_tangent", "sketch.circle.three_tangent"], prefix: "sketch.circle."),
        Slot(title: String(localized: "Arc"), ids: ["sketch.arc.three_point", "sketch.arc.center_point", "sketch.arc.tangent"], prefix: "sketch.arc."),
        Slot(title: String(localized: "Polygon"), ids: ["sketch.polygon.circumscribed", "sketch.polygon.inscribed", "sketch.polygon.edge"], prefix: "sketch.polygon."),
        Slot(ids: ["sketch.ellipse"]),
        Slot(title: String(localized: "Slot"), ids: ["sketch.slot.center_to_center", "sketch.slot.overall", "sketch.slot.center_point",
                                                       "sketch.slot.three_point_arc", "sketch.slot.center_point_arc"], prefix: "sketch.slot."),
        Slot(title: String(localized: "Spline"), ids: ["sketch.spline.fit_point", "sketch.spline.control_point"], prefix: "sketch.spline."),
        Slot(ids: [], prefix: "sketch.conic"),
        Slot(ids: ["sketch.point"]),
        Slot(ids: [], prefix: "sketch.text"),
        Slot(ids: ["sketch.mirror"]),
        Slot(ids: ["sketch.pattern.circular"]),
        Slot(ids: ["sketch.pattern.rectangular"]),
        Slot(title: String(localized: "Project / Include"), ids: ["sketch.project", "sketch.intersect", "sketch.include", "sketch.include_3d",
                                                                    "sketch.intersection_curve"], prefix: "sketch.project"),
        Slot(ids: ["sketch.dimension"]),
    ]

    /// The sketch MODIFY dropdown in the reference's order.
    private static let modifySlots: [Slot] = [
        Slot(ids: ["sketch.fillet"]), Slot(ids: ["sketch.chamfer"]), Slot(ids: ["sketch.trim"]), Slot(ids: ["sketch.extend"]),
        Slot(ids: ["sketch.break"]), Slot(ids: ["sketch.offset"]), Slot(ids: [], prefix: "sketch.move"),
        Slot(ids: [], prefix: "sketch.scale"),
    ]

    /// The big icons of the sketch CREATE and MODIFY panels, as on the reference's row.
    static let createRow = ["sketch.line", "sketch.rectangle.two_point", "sketch.circle.center", "sketch.spline.fit_point",
                            "sketch.mirror", "sketch.dimension", "sketch.point"]
    static let modifyRow = ["sketch.fillet", "sketch.trim", "sketch.offset", "sketch.extend"]

    /// The dropdown of a sketch CREATE or MODIFY panel, in the reference's order with its
    /// submenus; commands the reference does not place follow in registry order. Nil for
    /// every other panel.
    static func entries(_ panel: RibbonPanelModel) -> [MenuEntry]? {
        guard panel.commands.contains(where: { $0.tab == "SKETCH" }) else { return nil }
        let slots: [Slot]
        switch panel.name.uppercased() {
        case createPanel: slots = createSlots
        case modifyPanel: slots = modifySlots
        default: return nil
        }
        var left = panel.commands
        var out: [MenuEntry] = []
        for slot in slots {
            var picked: [CommandInfo] = []
            for id in slot.ids { if let i = left.firstIndex(where: { $0.id == id }) { picked.append(left.remove(at: i)) } }
            if let p = slot.prefix {
                while let i = left.firstIndex(where: { $0.id.hasPrefix(p) }) { picked.append(left.remove(at: i)) }
            }
            guard !picked.isEmpty else { continue }
            if let t = slot.title, picked.count > 1 { out.append(.submenu(t, picked)) } else { out += picked.map { .command($0) } }
        }
        return out + left.map { .command($0) }
    }

    /// The panel's commands in the reference's order (big icons, MORE menu, palette).
    static func ordered(_ panel: RibbonPanelModel) -> RibbonPanelModel {
        guard let e = entries(panel) else { return panel }
        return RibbonPanelModel(name: panel.name, commands: e.flatMap(\.commands))
    }

    /// The big icons of a sketch panel, in the reference's row order; nil for other panels.
    static func mainRow(_ panel: RibbonPanelModel) -> [CommandInfo]? {
        guard entries(panel) != nil else { return nil }
        let row = panel.name.uppercased() == createPanel ? createRow : modifyRow
        let picked = row.compactMap { id in panel.commands.first { $0.id == id } }
        return picked.isEmpty ? nil : picked
    }

    /// The registry's spelling of a panel ("CREATE", "Create"), else the reference name.
    private static func panelName(_ name: String, in panels: [RibbonPanelModel]) -> String {
        panels.first { $0.name.uppercased() == name }?.name ?? name
    }

    /// The armed sketch tool's prompt for the status bar, after the sketch's own line.
    static func hint(_ model: DesignModel) -> String? {
        guard model.sketchOpen, model.tool.isSketchTool, model.tool != .select else { return nil }
        return model.drawingHint
    }

    /// An armed tool that Return or Done moves on: a line or spline chain, typed sizes, or
    /// Mirror and the patterns waiting for their line or place.
    static func toolDoneShown(_ model: DesignModel) -> Bool {
        guard model.sketchOpen, model.genericCommand == nil, model.tool != .select, model.tool.isSketchTool else { return false }
        return model.tool.takesSketchEntities || model.tool == .line || model.tool == .spline || model.tool == .dimension
            || !model.sizeFields.isEmpty
    }
}

/// Done for the armed sketch tool (Return): ends the chain, places typed sizes, or moves Mirror
/// and the patterns on to their second step. Finish Sketch stays next to it.
struct SketchToolDoneButton: View {
    let model: DesignModel

    var body: some View {
        Button {
            model.endChain()
        } label: {
            HStack(spacing: VFSpace.s) {
                Text("Done")
                Image(systemName: "return").font(VFFont.glyph(10, weight: .semibold)).opacity(0.85)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.vfSecondary)
        .keyboardShortcut(.return, modifiers: [])
        .help(String(localized: "Finish \(StageLabels.command(model.tool.label)) (Return)"))
        .accessibilityLabel(String(localized: "Finish \(StageLabels.command(model.tool.label))"))
    }
}
#endif
