#if os(macOS)
import SwiftUI

/// The confirmation corner (M-18, after SolidWorks): a check and an X under the view cube while
/// a sketch or a command runs. The check finishes the command, else the sketch; the X cancels
/// the command, else leaves the sketch without keeping its changes (`sketch.cancel`). A SolidWorks extra: shown only with
/// Settings > SolidWorks extras on (SolidWorksExtras).
struct ConfirmationCorner: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    /// The view cube's height in DesignCanvas (92 pt) plus its margin: the corner sits under it.
    static let cubeHeight: CGFloat = 96

    /// Shown while a sketch is open or a tool or registry command is armed.
    static func shown(_ m: DesignModel) -> Bool { m.sketchOpen || m.tool != .select || m.genericCommand != nil }

    /// A command (not a sketch drawing tool) is running.
    private static func commandRunning(_ m: DesignModel) -> Bool {
        m.genericCommand != nil || (m.tool != .select && !m.tool.isSketchTool)
    }

    var body: some View {
        let running = Self.commandRunning(model)
        HStack(spacing: VFSpace.xxs) {
            // A registry command's form owns its OK (its fields may be missing): no check for it.
            if model.genericCommand == nil {
                button("checkmark", running ? String(localized: "OK") : String(localized: "Finish Sketch"),
                       help: running ? String(localized: "Finish the command (Return)") : String(localized: "Finish the sketch and keep it (Return)"),
                       tint: theme.accentText) { Self.accept(model) }
            }
            button("xmark", running ? String(localized: "Cancel") : String(localized: "Cancel Sketch"),
                   help: running ? String(localized: "Cancel the command (Esc)") : String(localized: "Leave the sketch without keeping the changes"),
                   tint: theme.inkSecondary) { Self.reject(model) }
        }
        .padding(VFSpace.xxs)
        .vfSurface(.floating, radius: VFRadius.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirmation corner")
    }

    private func button(_ symbol: String, _ label: String, help: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(VFFont.glyph(15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: VFSize.minTarget, height: VFSize.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    /// The check: finish the running command, else the sketch.
    static func accept(_ m: DesignModel) {
        if commandRunning(m) { CommandDialog.finish(m) } else if m.sketchOpen { m.finishSketch() } else { m.tool = .select }
    }

    /// The X: cancel the running command, else leave the sketch and drop its changes.
    static func reject(_ m: DesignModel) {
        if commandRunning(m) {
            if m.genericCommand != nil { m.genericCommand = nil } else { m.cancelTool(); m.tool = .select }
            return
        }
        if m.sketchOpen {
            m.tool = .select
            m.run("sketch.cancel", quiet: true)
        } else {
            m.tool = .select
        }
    }
}
#endif
