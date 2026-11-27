import SwiftUI
import simd

// Small leaves of the stage shell shared by the Mac and iPad windows: the product's own words for
// the engine's tab and command names, a PIPELINE OUTPUTS row, the job capsule, the axis triad and
// the status bar. They read `FlowModel` values and the theme, nothing platform specific.

/// The words the interface shows for the engine's registry names. The engine keeps its ids and
/// raw tab names; only what is drawn changes.
enum StageLabels {
    /// A ribbon tab: the product's own names.
    static func tab(_ raw: String) -> String {
        switch raw {
        case "SOLID": "BODY"
        case "SURFACE": "FREEFORM"
        case "MESH": "FACETS"
        case "SHEET METAL": "FOLD"
        case "PLASTIC": "MOLD"
        case "UTILITIES": "TOOLS"
        case "WELDMENTS": "FRAMES"
        case "RENDER SCENE": "SCENE"
        case "INSERT": "IMPORT"
        case "INSPECT": "CHECK"
        default: raw
        }
    }

    /// A ribbon panel caption: the product's own words for the engine's panel names.
    static func panel(_ raw: String) -> String {
        let up = raw.uppercased()
        switch up {
        case "CREATE": return "MAKE"
        case "MODIFY": return "EDIT"
        case "CONSTRUCT": return "PLANES"
        case "INSPECT": return "CHECK"
        case "INSERT": return "IMPORT"
        case "": return "OTHER"
        default:
            // "SURFACE CREATE", "MESH MODIFY": map the last word, keep the rest.
            for (k, v) in [("CREATE", "MAKE"), ("MODIFY", "EDIT"), ("CONSTRUCT", "PLANES"), ("INSPECT", "CHECK"), ("INSERT", "IMPORT")] where up.hasSuffix(" " + k) {
                return group(String(up.dropLast(k.count))) + v
            }
            return group(up)
        }
    }

    /// A command label.
    static func command(_ raw: String) -> String {
        switch raw {
        case "Press Pull", "Press/Pull", "PressPull": "Push / Pull"
        default: raw.replacingOccurrences(of: "ViewCube", with: "View cube")
        }
    }

    /// A catalog group ("SOLID CREATE" reads "BODY CREATE").
    static func group(_ raw: String) -> String {
        for t in ["SHEET METAL", "RENDER SCENE", "SOLID", "SURFACE", "MESH", "PLASTIC", "UTILITIES", "WELDMENTS", "INSERT", "INSPECT"] where raw.hasPrefix(t) {
            return tab(t) + raw.dropFirst(t.count)
        }
        return raw
    }

    /// An SF Symbol for an app verb's icon name in the flow catalog.
    static func symbol(forVerb icon: String) -> String {
        switch icon {
        case "generate": "wand.and.rays"
        case "promote": "arrow.up.forward.square"
        case "load": "arrow.down.to.line"
        case "stop": "stop.fill"
        case "fly": "paperplane"
        case "rerun": "arrow.clockwise"
        case "race": "flag.checkered"
        case "stress": "waveform.path.ecg"
        case "wind": "wind"
        case "record": "record.circle"
        case "train": "brain"
        case "render": "camera.aperture"
        case "export": "square.and.arrow.up"
        case "bom": "list.bullet.rectangle"
        case "board": "cpu"
        case "check": "checkmark.seal"
        case "link": "link"
        case "library": "books.vertical"
        case "update": "arrow.triangle.2.circlepath"
        case "flow": "point.3.connected.trianglepath.dotted"
        case "stage": "square.stack.3d.up"
        case "component": "memorychip"
        case "footprint": "square.dashed"
        case "wire": "point.topleft.down.to.point.bottomright.curvepath"
        case "track": "scribble"
        case "calibrate": "scope"
        case "teleop": "gamecontroller"
        case "path": "point.bottomleft.forward.to.point.topright.scurvepath"
        default: "command"
        }
    }
}

extension Workspace {
    /// The theme stage for this workspace.
    var vfStage: VFStage { VFStage(rawValue: stage) ?? .design }
}

/// A PIPELINE OUTPUTS row: the artifact, its revision, its state, and when stale or failed the
/// reason and the one action that fixes it.
struct OutputRow: View {
    @Environment(\.viaFormTheme) private var theme
    let output: FlowModel.Output
    var onOpen: () -> Void = {}
    var onAction: ((FlowModel.Action) -> Void)?
    /// What the action button says: "Update" when it rebuilds, "Open" when it can only take
    /// you to the stage that needs a person.
    var actionTitle: (FlowModel.Action) -> String = { _ in String(localized: "Update") }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: VFSpace.s) {
                Image(systemName: Workspace(stage: output.stage)?.symbol ?? "shippingbox")
                    .font(VFFont.glyph(11))
                    .foregroundStyle(theme.inkSecondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Button(action: onOpen) {
                    // "Frame v12" already names the artifact; before a first build, its label.
                    Text(output.revision_name ?? (output.label.isEmpty ? output.name : output.label))
                        .lineLimit(1)
                    .font(VFFont.small)
                    .foregroundStyle(theme.ink)
                }
                .buttonStyle(.plain)
                Spacer(minLength: VFSpace.xs)
                VFStatusDot(status: output.status.vfStatus, reason: output.reason.isEmpty ? nil : output.reason)
                    .accessibilityHidden(true)
                Text(output.status.vfStatus.word)
                    .font(VFFont.micro)
                    .foregroundStyle(theme.color(output.status))
                    .lineLimit(1)
                    .fixedSize()
            }
            if output.status == .stale || output.status == .failed, !output.reason.isEmpty || output.action != nil {
                HStack(spacing: VFSpace.xs) {
                    // One line: the root cause; the whole story on hover.
                    Text(output.reason)
                        .font(VFFont.micro)
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(output.reason)
                    Spacer(minLength: VFSpace.xs)
                    if let a = output.action, let onAction {
                        Button(actionTitle(a)) { onAction(a) }
                            .buttonStyle(.vfGhost(tint: theme.accentText))
                            .font(VFFont.micro.weight(.semibold))
                            .help(a.label)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, VFSpace.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// The running job of a stage over its viewport: verb, count, time left, pause when the job can
/// pause, and Stop. Liquid Glass: it is a control floating on the viewport.
struct JobCapsule: View {
    @Environment(\.viaFormTheme) private var theme
    let job: FlowModel.RunningJob
    var pause: (() -> Void)?
    var resume: (() -> Void)?
    var cancel: (() -> Void)?
    private static let height: CGFloat = 32

    var body: some View {
        HStack(spacing: VFSpace.s) {
            if job.determinate {
                ProgressView(value: job.progress).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(job.caption.isEmpty ? job.label : job.caption)
                .font(VFFont.small.weight(.medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            if job.pausable, (job.paused ? resume : pause) != nil {
                VFIconButton(job.paused ? "play.fill" : "pause.fill",
                             label: job.paused ? String(localized: "Resume \(job.label)") : String(localized: "Pause \(job.label)"),
                             size: 11) {
                    job.paused ? resume?() : pause?()
                }
            }
            if let cancel {
                VFIconButton("stop.fill", label: String(localized: "Stop \(job.label)"), size: 11, action: cancel)
            }
        }
        .padding(.leading, VFSpace.l)
        .padding(.trailing, VFSpace.xs)
        .frame(height: Self.height)
        .vfSurface(.control, radius: Self.height / 2)
        .accessibilityElement(children: .contain)
    }
}

/// The X, Y, Z axes as the camera sees them, drawn in a corner of the viewport.
struct AxisTriad: View {
    @Environment(\.viaFormTheme) private var theme
    let camera: OrbitCamera
    var length: CGFloat = 26

    var body: some View {
        let (r, u, _) = camera.basis
        let axes: [(String, SIMD3<Double>, Color)] = [
            ("X", SIMD3(1, 0, 0), theme.danger),
            ("Y", SIMD3(0, 1, 0), theme.success),
            ("Z", SIMD3(0, 0, 1), theme.accent),
        ]
        Canvas { ctx, size in
            let o = CGPoint(x: size.width / 2, y: size.height / 2)
            for (name, a, color) in axes {
                let d = CGPoint(x: simd_dot(a, r) * length, y: -simd_dot(a, u) * length)
                var p = Path()
                p.move(to: o)
                p.addLine(to: CGPoint(x: o.x + d.x, y: o.y + d.y))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                let tip = CGPoint(x: o.x + d.x * 1.32, y: o.y + d.y * 1.32)
                ctx.draw(Text(name).font(VFFont.micro.weight(.semibold)).foregroundStyle(color), at: tip)
            }
        }
        .frame(width: length * 3, height: length * 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The bottom line of the window: what is selected, the stage's state, and the core's health.
/// Every status mark is a shape plus a word, never a colour alone.
struct StageStatusBar: View {
    @Environment(\.viaFormTheme) private var theme
    let leading: String
    var items: [String] = []
    var coreOK = true
    var trailing: AnyView?
    /// The open stage's artifact status, shown by the leading mark.
    var status: FlowModel.Status = .current

    var body: some View {
        HStack(spacing: VFSpace.l) {
            VFStatusDot(status: status.vfStatus)
            Text(leading).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: VFSpace.m)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item).monospacedDigit().lineLimit(1)
            }
            HStack(spacing: VFSpace.xs) {
                VFStatusDot(status: coreOK ? .current : .failed,
                            reason: coreOK ? nil : String(localized: "Restart ViaForm to bring the core back."))
                    .accessibilityHidden(true)
                Text(coreOK ? "Core running" : "Core stopped")
            }
            .accessibilityElement(children: .combine)
            .help(coreOK ? String(localized: "The ViaForm core is running.") : String(localized: "The ViaForm core stopped. Restart ViaForm to bring it back."))
            if let trailing { trailing }
        }
        .font(VFFont.small)
        .foregroundStyle(theme.inkSecondary)
        .padding(.horizontal, VFSpace.l)
        .frame(height: 24)
        .vfSurface(.chrome)
        .overlay(alignment: .top) { VFHairline() }
    }
}
