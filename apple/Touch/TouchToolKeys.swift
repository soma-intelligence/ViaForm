#if os(iOS)
import SwiftUI

// Single-letter tool keys with a hardware keyboard on the iPad (gap T-18), after the Mac's
// registry key map (Desk/DeskKeys.swift): every registry command with a plain or shifted letter
// (E Extrude, F Fillet, M Move, L Line, ...) runs from the keyboard in the 3D stages. In an open
// sketch the sketch commands win a shared letter. Space sketches on the picked face. Typing in a
// field keeps its letters: text input comes first, and the action checks again on the press.

enum TouchKeymap {
    /// "E", "Shift+R": a letter the window takes without Command or Control.
    static func isLetterKey(_ k: String) -> Bool {
        let parts = k.split(separator: "+")
        guard let last = parts.last, last.count == 1, last.first?.isLetter == true else { return false }
        return parts.dropLast().allSatisfy { $0.lowercased() == "shift" }
    }

    /// The registry command a key runs. A shared letter goes to the sketch command while a sketch
    /// is open, then to the modelling commands.
    @MainActor static func command(for key: String, model: DesignModel) -> CommandInfo? {
        let hits = model.commands.filter { ($0.key ?? "").caseInsensitiveCompare(key) == .orderedSame }
        return hits.min { rank($0, model) < rank($1, model) }
    }

    @MainActor private static func rank(_ c: CommandInfo, _ m: DesignModel) -> Int {
        if m.sketchOpen, c.id.hasPrefix("sketch.") { return 0 }
        if c.id.hasPrefix("sketch.") || c.id.hasPrefix("solid.") || c.id.hasPrefix("inspect.") { return 1 }
        if c.id.hasPrefix("render.") || c.id.hasPrefix("appearance.") { return 3 }
        return 2
    }

    /// Every letter key of the registry, once each.
    @MainActor static func keys(_ model: DesignModel) -> [String] {
        var keys: [String] = []
        for c in model.commands {
            guard let k = c.key, isLetterKey(k), !keys.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) else { continue }
            keys.append(k)
        }
        return keys.sorted()
    }

    /// Rows for the shortcuts sheet: "E" Extrude, "⇧R" ...
    @MainActor static func rows(_ model: DesignModel) -> [(keys: String, title: String)] {
        var out: [(String, String)] = keys(model).compactMap { k in
            command(for: k, model: model).map { (glyph(k), StageLabels.command($0.label)) }
        }
        out.append(("Space", String(localized: "Sketch on the picked face")))
        out.append(("⌘F", String(localized: "Search commands")))
        out.append(("⇧⌘A", String(localized: "Deselect all")))
        return out
    }

    static func glyph(_ k: String) -> String {
        let parts = k.split(separator: "+").map(String.init)
        return parts.dropLast().map { $0.lowercased() == "shift" ? "⇧" : $0 }.joined() + (parts.last?.uppercased() ?? "")
    }

    /// What a registry command does when its key is pressed (as the Mac's `CommandRouter`).
    @MainActor static func run(_ c: CommandInfo, _ m: DesignModel) {
        switch c.id {
        case "sketch.finish": m.finishSketch(); return
        case "edit.undo": m.undo(); return
        case "edit.redo": m.redo(); return
        case "solid.combine": m.genericCommand = c; return
        case "solid.remove": m.deleteSelection(); return
        case "inspect.measure": m.measureSelection(); return
        default: break
        }
        if let t = Tool.allCases.first(where: { $0.commandID == c.id }), t != .union, t != .subtract, t != .intersect {
            m.genericCommand = nil
            TouchToolActions.activate(t, m)
        } else {
            m.tool = .select
            m.genericCommand = c
        }
    }

    /// The key press, checked at the moment it lands.
    @MainActor static func press(_ key: String, model: DesignModel) -> Bool {
        guard !TouchResponder.isEditingText, let c = command(for: key, model: model) else { return false }
        run(c, model)
        return true
    }
}

/// The letter keys as hidden buttons with no modifier (or Shift), for the window that shows the
/// 3D design. Place it in the background of the design stage with `enabled` false while a sheet,
/// the palette or a text field is up.
struct TouchToolKeys: View {
    let model: DesignModel
    var enabled = true
    let showPalette: () -> Void

    var body: some View {
        ZStack {
            ForEach(TouchKeymap.keys(model), id: \.self) { k in
                let shifted = k.lowercased().hasPrefix("shift+")
                if let ch = k.split(separator: "+").last?.lowercased().first {
                    Button(TouchKeymap.command(for: k, model: model).map { StageLabels.command($0.label) } ?? k) {
                        _ = TouchKeymap.press(k, model: model)
                    }
                    .keyboardShortcut(KeyEquivalent(ch), modifiers: shifted ? [.shift] : [])
                }
            }
            Button("Sketch on Face") {
                guard !TouchResponder.isEditingText else { return }
                if model.selection.contains(where: \.isFace) { model.sketchOnSelectedFace() } else { model.tool = .sketch }
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("Search Commands", action: showPalette).keyboardShortcut("f", modifiers: .command)
            Button("Deselect All") { model.selection = []; model.selectedBodies = [] }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        .disabled(!enabled)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
#endif
