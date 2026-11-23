import SwiftUI

// Viewport navigation presets (decision D-21) and the first-visit stage introduction
// (FRONTEND-SPEC 7.7).

/// How the mouse and trackpad move the camera. ViaForm is the default; the others match the
/// tools people come from, so their hands do not have to relearn.
enum MousePreset: String, CaseIterable, Identifiable, Sendable {
    case viaform, fusion, blender, onshape

    static let storageKey = "viaform.navigation.preset"
    static var current: MousePreset {
        MousePreset(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .viaform
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .viaform: "ViaForm"
        case .fusion: "Fusion"
        case .blender: "Blender"
        case .onshape: "Onshape"
        }
    }

    enum Move: Equatable { case orbit, pan, zoom, none }

    /// Middle button drag, with or without Shift or Control.
    func middleDrag(shift: Bool, control: Bool) -> Move {
        switch self {
        case .viaform, .fusion: shift ? .orbit : .pan
        case .blender: control ? .zoom : (shift ? .pan : .orbit)
        case .onshape: .pan
        }
    }

    /// Right button drag (a right click without a drag opens the marking menu in every preset).
    func rightDrag(control: Bool) -> Move {
        switch self {
        case .viaform: .orbit
        case .fusion: .none
        case .blender: .none
        case .onshape: control ? .pan : .orbit
        }
    }

    /// Left drag with a modifier on empty space (Option, Command).
    func leftDrag(option: Bool, command: Bool) -> Move {
        switch self {
        case .viaform: option ? .orbit : (command ? .pan : .none)
        case .fusion: option ? .orbit : .none
        case .blender: option ? .orbit : .none
        case .onshape: option ? .orbit : .none
        }
    }

    /// Two-finger trackpad scroll.
    func trackpad(shift: Bool, option: Bool) -> Move {
        switch self {
        case .viaform, .onshape: (option || shift) ? .orbit : .pan
        case .fusion: shift ? .orbit : .pan
        case .blender: shift ? .pan : .orbit
        }
    }

    /// A line per gesture for the Settings pane.
    var summary: [(gesture: String, move: String)] {
        let orbit = String(localized: "Orbit"), pan = String(localized: "Pan"), zoom = String(localized: "Zoom")
        switch self {
        case .viaform:
            return [("Right drag", orbit), ("Middle drag", pan), ("Shift middle drag", orbit), ("Option drag", orbit),
                    ("Command drag", pan), ("Scroll wheel or pinch", zoom),
                    ("Two fingers", pan), ("Option or Shift two fingers", orbit)]
        case .fusion:
            return [("Middle drag", pan), ("Shift middle drag", orbit), ("Option drag", orbit), ("Scroll wheel or pinch", zoom),
                    ("Two fingers", pan), ("Shift two fingers", orbit)]
        case .blender:
            return [("Middle drag", orbit), ("Shift middle drag", pan), ("Control middle drag", zoom), ("Scroll wheel or pinch", zoom),
                    ("Two fingers", orbit), ("Shift two fingers", pan)]
        case .onshape:
            return [("Right drag", orbit), ("Middle drag", pan), ("Control right drag", pan), ("Scroll wheel or pinch", zoom),
                    ("Two fingers", pan), ("Option two fingers", orbit)]
        }
    }
}

/// The Navigation settings pane: preset picker and what each gesture does.
struct NavigationSettings: View {
    @AppStorage(MousePreset.storageKey) private var preset = MousePreset.viaform.rawValue

    var body: some View {
        Form {
            Picker("Mouse and trackpad", selection: $preset) {
                ForEach(MousePreset.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Section("Gestures") {
                ForEach(Array((MousePreset(rawValue: preset) ?? .viaform).summary.enumerated()), id: \.offset) { _, row in
                    LabeledContent(LocalizedStringKey(row.gesture), value: row.move)
                }
            }
            Section {
                Text("Click selects, Shift-click adds, Command-click toggles. A right click without a drag opens the marking menu.")
                    .font(VFFont.small)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Stage introduction

/// "What this stage does": shown once per stage, dismissed for good, reset from Settings.
struct StageIntro: View {
    @Environment(\.viaFormTheme) private var theme
    let workspace: Workspace
    @State private var dismissed = true

    private static func key(_ w: Workspace) -> String { "viaform.intro.\(w.stage)" }

    static func resetAll() {
        for w in Workspace.allCases { UserDefaults.standard.removeObject(forKey: key(w)) }
    }

    /// Screenshots and tests launch with `--no-intro`.
    private static var suppressed: Bool { ProcessInfo.processInfo.arguments.contains { $0 == "--no-intro" || $0.hasPrefix("--window-size") } }

    var body: some View {
        Group {
            if !dismissed {
                VStack(alignment: .leading, spacing: VFSpace.m) {
                    HStack(spacing: VFSpace.s) {
                        Image(systemName: workspace.symbol).foregroundStyle(theme.accentText).accessibilityHidden(true)
                        Text(workspace.title).font(VFFont.title).foregroundStyle(theme.ink)
                        Spacer()
                        VFIconButton("xmark", label: String(localized: "Dismiss introduction"), size: 10) { dismiss() }
                    }
                    Text(Self.text(workspace)).font(VFFont.row).foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Got It") { dismiss() }.buttonStyle(.vfSecondary)
                }
                .padding(VFSpace.l)
                .frame(maxWidth: 340, alignment: .leading)
                .vfSurface(.floating)
                .vfTransition(.opacity)
            }
        }
        .onAppear { dismissed = Self.suppressed || UserDefaults.standard.bool(forKey: Self.key(workspace)) }
        .onChange(of: workspace) { _, w in dismissed = Self.suppressed || UserDefaults.standard.bool(forKey: Self.key(w)) }
    }

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: Self.key(workspace))
        dismissed = true
    }

    static func text(_ w: Workspace) -> String {
        switch w {
        case .design: String(localized: "Model the parts: sketch, extrude, fillet. Try: press K and click a face to sketch on it.")
        case .generate: String(localized: "Let the solver find a light, strong shape. Set supports and loads, then Run. Stop with Command-period.")
        case .assemble: String(localized: "Join parts with joints and check how they move. Try: press T and drag the gripper tip.")
        case .electronics: String(localized: "Draw the schematic, place the board, route it, then send it to the 3D model.")
        case .simulation: String(localized: "Fly or drive the product in physics before building it. Results feed Generate and Train.")
        case .train: String(localized: "Train a control policy in simulation. Runs show progress here and can be stopped any time.")
        case .render: String(localized: "Make product shots of the current model.")
        case .make: String(localized: "Export the files to print, cut and order, with the bill of materials.")
        case .robot: String(localized: "Drive the real robot. The e-stop is always here: Space, or Esc twice.")
        }
    }
}
