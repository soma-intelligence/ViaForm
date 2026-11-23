#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Assemble stage's ribbon (VIAFORM-SPEC 7.3): ASSEMBLY (the document: template, commit,
/// MJCF and URDF), JOINTS (select, turn a joint, poses), MOTION (drag tip, grasp, motion study,
/// save pose) and CHECK (interference, mass). The commit to the flow sits on the trailing edge.
struct AssembleRibbon: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    @Bindable var model: AssembleModel
    let flow: FlowModel
    var showBottom: () -> Void = {}
    @State private var confirm: ConfirmRequest?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(AssembleModel.Tab.allCases) { t in
                    let on = model.tab == t
                    Button { select(t) } label: {
                        Text(t.title)
                            .textCase(.uppercase)
                            .font(VFFont.caps)
                            .tracking(VFTypeScale.capsTracking)
                            .padding(.horizontal, VFSpace.m)
                            .frame(height: 24)
                            .foregroundStyle(on ? theme.accentText : theme.inkSecondary)
                            .overlay(alignment: .bottom) { if on { Rectangle().fill(theme.accent).frame(height: 2) } }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, VFSpace.xs)
            .frame(height: 24)
            .overlay(alignment: .bottom) { VFHairline() }
            HStack(spacing: VFSpace.s) {
                tools
                Spacer(minLength: VFSpace.m)
                trailing
            }
            .padding(.horizontal, VFSpace.m)
            .padding(.vertical, VFSpace.xs)
            .frame(height: 60)
        }
        .vfSurface(.ribbon)
        .confirmSheet($confirm)
    }

    private func select(_ t: AssembleModel.Tab) {
        model.tab = t
        switch t {
        case .motion: if model.tool == .select || model.tool == .rotateJoint { model.tool = model.product == .hand ? .grasp : .dragTip }
        case .joints: model.tool = .select
        case .check: model.tool = .select; if model.interference == nil { model.checkInterference() }
        case .assembly: model.tool = .select
        }
    }

    @ViewBuilder private var tools: some View {
        switch model.tab {
        case .assembly:
            tool("New Arm", "plus.square.on.square", help: "Replace with the six-joint arm template") {
                confirm = ConfirmRequest(title: String(localized: "Replace the assembly with the arm template?"),
                                         message: String(localized: "The six-joint arm template replaces this assembly, with its joints, saved poses and grasps."),
                                         verb: String(localized: "Replace with Arm"), destructive: true) { model.openArm(flow: flow) }
            }
            tool("Commit", "checkmark.seal", help: "Record this assembly as a new revision in the flow") { model.commit() }
            divider
            tool("MJCF", "square.and.arrow.up", help: "Export the assembly as MJCF (MuJoCo XML)") { export("export_mjcf") }
            tool("URDF", "square.and.arrow.up.on.square", help: "Export the assembly as URDF") { export("export_urdf") }
        case .joints:
            tool("Select", "cursorarrow", on: model.tool == .select, help: "Pick a part to select its joint") { model.tool = .select }
            tool("Turn Joint", "arrow.triangle.2.circlepath", on: model.tool == .rotateJoint, help: "Drag the ring to turn the selected joint") {
                model.tool = .rotateJoint
                if model.selectedJoint == nil { model.selectedJoint = model.joints.first?.id }
            }
            divider
            Menu {
                if (model.doc?.poses ?? []).isEmpty { Text("No saved poses") }
                ForEach(model.doc?.poses ?? []) { p in Button(AsmFormat.title(p.id)) { model.pose(named: p.id) } }
            } label: { label("Poses", "bookmark") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Move to a saved pose")
            tool("Save Pose", "bookmark.fill", help: "Save the current joint values as a pose") { model.savePose() }
        case .motion:
            tool("Drag Tip", "cursorarrow.motionlines", on: model.tool == .dragTip, key: "T", help: "Drag the end effector; the joints follow (T)") { model.tool = .dragTip }
                .vfDisabled(model.product != .arm, reason: String(localized: "For arms: a hand moves with the grasp editor"))
            tool("Grasp", "hand.raised", on: model.tool == .grasp, key: "G", help: "Place fingertip targets on an object (G)") { model.tool = .grasp }
                .vfDisabled(model.product != .hand, reason: String(localized: "For hands: the arm's gripper has one joint"))
            divider
            tool("Motion Study", "waveform.path.ecg", help: "Show the motion study in the bottom panel") {
                showBottom()
                if model.study == nil { model.runStudy(thenPlay: true) } else { model.play() }
            }
            tool("Save Pose", "bookmark.fill", help: "Save the current joint values as a pose") { model.savePose() }
            tool("Home", "house", help: "Back to the home pose") { model.pose(named: "home") }
        case .check:
            tool("Interference", "square.on.square.intersection.dashed", help: "Check every pair of parts at this pose") { model.checkInterference() }
            tool("Mass", "scalemass", help: "Mass properties: total, centre of mass, inertia") { model.computeMass() }
            tool("Sweep Check", "waveform.path.ecg.rectangle", help: "Interference over the motion study") {
                showBottom()
                model.runStudy()
            }
        }
    }

    private var divider: some View { VFHairline(vertical: true).frame(height: 40).padding(.horizontal, VFSpace.xs) }

    private var trailing: some View {
        HStack(spacing: VFSpace.s) {
            if let p = model.studyProgress {
                StudyProgressRow(progress: p) { model.stopWork() }
                    .frame(width: 220)
                VFHairline(vertical: true).frame(height: 28)
            }
            if let c = flow.node("assemble.assembly")?.revisionName ?? model.committed {
                Text(c).font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            Button { model.commit() } label: {
                HStack(spacing: VFSpace.s) {
                    Text("Commit Assembly")
                    Text(verbatim: "\u{2318}\u{21A9}").font(VFFont.micro).opacity(0.7).accessibilityHidden(true)
                }
            }
            .buttonStyle(.vfPrimary)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Record the assembly in the flow (commit, then the pipeline marks what uses it)")
        }
        .fixedSize()
    }

    private func tool(_ title: LocalizedStringResource, _ symbol: String, on: Bool = false, key: String? = nil, help: LocalizedStringResource,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { label(String(localized: title), symbol, on: on) }
            .buttonStyle(.plain)
            .help(Text(help))
            .accessibilityLabel(Text(title))
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func label(_ title: String, _ symbol: String, on: Bool = false) -> some View {
        VStack(spacing: VFSpace.xs) {
            Image(systemName: symbol).font(VFFont.glyph(18)).frame(height: 22).accessibilityHidden(true)
            Text(title).textCase(.uppercase).font(VFFont.micro.weight(.semibold)).tracking(0.4).lineLimit(1)
        }
        .foregroundStyle(on ? theme.accentText : theme.ink)
        .padding(.horizontal, VFSpace.s)
        .frame(minWidth: 64, minHeight: 50)
        .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(on ? theme.accent.opacity(0.12) : .clear))
        .overlay(RoundedRectangle(cornerRadius: VFRadius.control).strokeBorder(on ? theme.accent.opacity(0.55) : .clear))
        .contentShape(Rectangle())
    }

    private func export(_ op: String) {
        do {
            let r = try model.engine.call(op)
            guard let text = r["text"] as? String else {
                toasts?.error(String(localized: "The export came back empty."))
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = r["filename"] as? String ?? (op == "export_mjcf" ? "assembly.xml" : "assembly.urdf")
            if panel.runModal() == .OK, let url = panel.url {
                try text.write(to: url, atomically: true, encoding: .utf8)
                toasts?.show(String(localized: "Exported \(url.lastPathComponent)"), actionTitle: String(localized: "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } catch {
            toasts?.error(String(localized: "Could not export: \(error.localizedDescription)"), actionTitle: String(localized: "Try Again")) { export(op) }
        }
    }
}
#endif
