#if os(macOS)
import AppKit
import SwiftUI

/// The Mac keymap: what a key does in the project window, the glyphs it is drawn with, and the
/// sheet that lists it all (? or Command-/).
///
/// The registry gives every design command its letter (E Extrude, F Fillet, H Hole, M Move,
/// J Joint, D Dimension, ...). Before this pass only the nine letters the Metal view knew did
/// anything; now a window-wide key monitor runs any registry letter in the 3D stages, whatever
/// has focus (the browser, the inspector, the viewport), unless a text field is being typed in.
/// The board and the flight keep their own keys (R, W, X on the board, W A S D in the air).
enum DeskKeymap {
    /// "Ctrl+Shift+A" as "⌃⇧A", "Cmd+1" as "⌘1", "Delete" as "⌫". Single letters stay.
    static func glyph(_ key: String) -> String {
        let parts = key.split(separator: "+").map(String.init)
        var out = ""
        for p in parts {
            switch p.lowercased() {
            case "ctrl", "control": out += "⌃"
            case "alt", "option", "opt": out += "⌥"
            case "shift": out += "⇧"
            case "cmd", "command": out += "⌘"
            case "delete", "backspace": out += "⌫"
            case "escape", "esc": out += "⎋"
            case "return", "enter": out += "↩"
            case "tab": out += "⇥"
            case "space": out += "Space"
            default: out += p.count == 1 ? p.uppercased() : p
            }
        }
        return out
    }

    /// Control-1 to Control-7: the registry's standard views.
    static func view(_ digit: Int) -> StandardView? {
        switch digit {
        case 1: .front
        case 2: .back
        case 3: .left
        case 4: .right
        case 5: .top
        case 6: .bottom
        case 7: .iso
        default: nil
        }
    }

    /// The letter keys the window handles itself before the registry.
    static let own: [String: String] = ["S": "Search commands", "K": "Sketch on a face or plane", "6": "Isometric view"]

    /// The registry command a plain or shifted letter runs in `workspace`. Two commands share
    /// R (rectangle, render) and I (measure, pick up appearance): the stage decides.
    @MainActor
    static func command(for key: String, in workspace: Workspace, model: DesignModel) -> CommandInfo? {
        let hits = model.commands.filter { ($0.key ?? "").caseInsensitiveCompare(key) == .orderedSame }
        return hits.min { rank($0, workspace, model) < rank($1, workspace, model) }
    }

    @MainActor
    private static func rank(_ c: CommandInfo, _ w: Workspace, _ m: DesignModel) -> Int {
        if w == .render, c.id.hasPrefix("render.") || c.id.hasPrefix("appearance.") { return 0 }
        if m.sketchOpen, c.id.hasPrefix("sketch.") { return 0 }
        if c.id.hasPrefix("sketch.") || c.id.hasPrefix("solid.") || c.id.hasPrefix("inspect.") || c.id.hasPrefix("joint.") { return 1 }
        if c.id.hasPrefix("render.") || c.id.hasPrefix("appearance.") { return 3 }
        return 2
    }

    /// Every single-key registry shortcut, one row per key (the command the Design stage runs).
    @MainActor
    static func registryRows(_ model: DesignModel, workspace: Workspace) -> [(keys: String, title: String)] {
        var keys: [String] = []
        for c in model.commands {
            guard let k = c.key, isLetterKey(k), !keys.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) else { continue }
            keys.append(k)
        }
        return keys.sorted().compactMap { k in
            command(for: k, in: workspace, model: model).map { (glyph(k), StageLabels.command($0.label)) }
        }
    }

    /// "E", "Shift+R": a key the monitor can take without a Command or Control modifier.
    static func isLetterKey(_ k: String) -> Bool {
        let parts = k.split(separator: "+")
        guard let last = parts.last, last.count == 1, last.first?.isLetter == true else { return false }
        return parts.dropLast().allSatisfy { $0.lowercased() == "shift" }
    }
}

/// Installs a key-down monitor for the window it is placed in. `handle` answers true when it
/// took the key (the event then stops there).
struct DeskKeyMonitor: NSViewRepresentable {
    var handle: (NSEvent) -> Bool
    /// Keys that must work even while a field is being edited (the robot e-stop, Esc twice).
    /// Called before the text field check; true takes the key.
    var urgent: (NSEvent) -> Bool = { _ in false }

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.handle = handle
        v.urgent = urgent
        return v
    }

    func updateNSView(_ v: MonitorView, context: Context) {
        v.handle = handle
        v.urgent = urgent
    }

    final class MonitorView: NSView {
        var handle: (NSEvent) -> Bool = { _ in false }
        var urgent: (NSEvent) -> Bool = { _ in false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w, w.isKeyWindow else { return e }
                // The e-stop first: Esc twice stops the robot even from a field or a sheet.
                if self.urgent(e) { return nil }
                guard w.attachedSheet == nil else { return e }
                // Typing in a field (the palette, a parameter, a rename) keeps every key.
                if w.firstResponder is NSText { return e }
                return self.handle(e) ? nil : e
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The keyboard sheet: every shortcut of the window, the open stage's group first.
struct ShortcutSheet: View {
    @Environment(\.viaFormTheme) private var theme
    let workspace: Workspace
    let model: DesignModel
    var close: () -> Void

    private typealias Row = (keys: String, title: String)

    private var window: [Row] {
        [("⌘K", "Search commands"), ("⌘1 … ⌘9", "Open a stage"), ("⌘] ⌘[", "Next, previous stage"),
         ("⌘↩", "Run the stage's main action"), ("⌘.", "Stop the running job"), ("⇧⌘U", "Update stale stages"), ("⌘Z ⇧⌘Z", "Undo, redo"),
         ("⌥⌘I", "Inspector"), ("⌃⌘S", "Sidebar"), ("⌥⌘B", "Bottom panel"), ("⇧⌘B", "Bill of materials"),
         ("⇧⌘L", "Libraries"), ("⌘S ⇧⌘S", "Save, save as"), ("? ⌘/", "This sheet"), ("Space, Esc Esc", "Robot e-stop")]
    }

    private var view3D: [Row] {
        [("⌃1 … ⌃7", "Front, back, left, right, top, bottom, iso"), ("6", "Isometric"), ("F6", "Zoom to fit"),
         ("S", "Search commands"), ("K", "Sketch"), ("↩", "Finish the command"), ("Esc", "Cancel, then clear the selection (never stops a job)"),
         ("⌫", "Delete the selection")]
    }

    private var board: [Row] {
        [("R", "Rotate the part"), ("W", "Wire"), ("X", "Route a track"), ("⌫", "Delete"), ("Esc", "Select tool")]
    }

    private var flight: [Row] {
        [("W S", "Pitch"), ("A D", "Roll"), ("↑ ↓ R F", "Throttle"), ("← → Q E", "Yaw"), ("Space", "Play, pause")]
    }

    private var groups: [(String, [Row])] {
        let design = ("Design commands", DeskKeymap.registryRows(model, workspace: StageActions.designLike.contains(workspace) ? workspace : .design))
        var out: [(String, [Row])] = [("Window", window)]
        switch workspace {
        case .electronics: out += [("Board", board), ("3D view", view3D), design]
        case .simulation, .train: out += [("Flight (manual mission)", flight), ("3D view", view3D), design]
        default: out += [design, ("3D view", view3D), ("Board", board)]
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(VFFont.title).foregroundStyle(theme.ink)
                Spacer()
                Text("Esc closes").font(VFFont.micro).foregroundStyle(theme.inkTertiary)
                VFIconButton("xmark", label: String(localized: "Close"), size: 10, action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, VFSpace.l).frame(minHeight: 40)
            VFHairline()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: VFSpace.xl, alignment: .top),
                                    GridItem(.flexible(), spacing: VFSpace.xl, alignment: .top),
                                    GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: VFSpace.l) {
                    ForEach(groups, id: \.0) { g in
                        VStack(alignment: .leading, spacing: 2) {
                            VFCaption(g.0).padding(.bottom, VFSpace.xs)
                            ForEach(Array(g.1.enumerated()), id: \.offset) { _, r in
                                HStack(spacing: VFSpace.m) {
                                    Text(LocalizedStringKey(r.title)).font(VFFont.small).foregroundStyle(theme.ink)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: VFSpace.s)
                                    KeyCap(r.keys)
                                }
                                .frame(minHeight: 20)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .padding(VFSpace.l)
            }
            .frame(maxHeight: 520)
        }
        .frame(maxWidth: 820)
        .vfSurface(.floating)
        .accessibilityAddTraits(.isModal)
    }
}

/// A key or chord in a thin outlined cap.
struct KeyCap: View {
    @Environment(\.viaFormTheme) private var theme
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(VFFont.mono).foregroundStyle(theme.inkSecondary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, VFSpace.xs).frame(minWidth: 18, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: VFRadius.mark).strokeBorder(theme.hairline))
    }
}
#endif
