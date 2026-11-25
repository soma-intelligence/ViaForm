#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Assemble stage's ribbon (VIAFORM-SPEC 7.3): ASSEMBLY (the document: template, commit,
/// MJCF and URDF), JOINTS (select, turn a joint, poses), MOTION (drag tip, grasp, motion study,
/// save pose) and CHECK (interference, mass). The commit to the flow sits on the trailing edge.
/// In a narrow window the tools fold like the stage ribbon (P2-7): names, then icons, then the
/// last groups into MORE.
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
                // Labelled tools, then icons only, then the last groups folded into MORE one by
                // one (P2-7, the same fold as the stage ribbon): never wider than the window,
                // every command reachable with its label, state and reason.
                let groups = Self.groups(model.tab)
                ViewThatFits(in: .horizontal) {
                    ForEach(RibbonFold.steps(groups.count), id: \.self) { step in
                        let r = RibbonFold.fold(groups, visible: step.visible)
                        HStack(spacing: VFSpace.s) {
                            ForEach(Array(r.strip.enumerated()), id: \.element.id) { i, g in
                                if i > 0 { divider }
                                ForEach(g.commands) { c in tool(c, labels: step.labels) }
                            }
                            if !r.more.isEmpty {
                                if !r.strip.isEmpty { divider }
                                more(r.more)
                            }
                        }
                        .fixedSize()
                    }
                }
                .layoutPriority(-1)
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

    // MARK: Commands

    /// One command of the Assemble ribbon: the same words in the strip and in MORE.
    nonisolated struct Command: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let symbol: String
        let help: String
        /// A mode the canvas stays in (a checkmark in MORE), not a one-shot action.
        var mode = false
        /// Opens the saved poses (a submenu in MORE).
        var posesMenu = false
    }

    /// The tab's commands in groups, highest priority first: the last group folds first.
    nonisolated static func groups(_ tab: AssembleModel.Tab) -> [RibbonFold.Group<Command>] {
        let savePose = Command(id: "savePose", title: String(localized: "Save Pose"), symbol: "bookmark.fill",
                               help: String(localized: "Save the current joint values as a pose"))
        switch tab {
        case .assembly:
            return [
                .init(name: String(localized: "Document"), commands: [
                    Command(id: "newArm", title: String(localized: "New Arm"), symbol: "plus.square.on.square",
                            help: String(localized: "Replace with the six-joint arm template")),
                    Command(id: "commit", title: String(localized: "Commit"), symbol: "checkmark.seal",
                            help: String(localized: "Record this assembly as a new revision in the flow")),
                ]),
                .init(name: String(localized: "Export"), commands: [
                    Command(id: "mjcf", title: String(localized: "MJCF"), symbol: "square.and.arrow.up",
                            help: String(localized: "Export the assembly as MJCF (MuJoCo XML)")),
                    Command(id: "urdf", title: String(localized: "URDF"), symbol: "square.and.arrow.up.on.square",
                            help: String(localized: "Export the assembly as URDF")),
                ]),
            ]
        case .joints:
            return [
                .init(name: String(localized: "Joint"), commands: [
                    Command(id: "select", title: String(localized: "Select"), symbol: "cursorarrow",
                            help: String(localized: "Pick a part to select its joint"), mode: true),
                    Command(id: "turnJoint", title: String(localized: "Turn Joint"), symbol: "arrow.triangle.2.circlepath",
                            help: String(localized: "Drag the ring to turn the selected joint"), mode: true),
                ]),
                .init(name: String(localized: "Poses"), commands: [
                    Command(id: "poses", title: String(localized: "Poses"), symbol: "bookmark",
                            help: String(localized: "Move to a saved pose"), posesMenu: true),
                    savePose,
                ]),
            ]
        case .motion:
            return [
                .init(name: String(localized: "Move"), commands: [
                    Command(id: "dragTip", title: String(localized: "Drag Tip"), symbol: "cursorarrow.motionlines",
                            help: String(localized: "Drag the end effector; the joints follow (T)"), mode: true),
                    Command(id: "grasp", title: String(localized: "Grasp"), symbol: "hand.raised",
                            help: String(localized: "Place fingertip targets on an object (G)"), mode: true),
                ]),
                .init(name: String(localized: "Study"), commands: [
                    Command(id: "motionStudy", title: String(localized: "Motion Study"), symbol: "waveform.path.ecg",
                            help: String(localized: "Show the motion study in the bottom panel")),
                    savePose,
                    Command(id: "home", title: String(localized: "Home"), symbol: "house",
                            help: String(localized: "Back to the home pose")),
                ]),
            ]
        case .check:
            return [
                .init(name: String(localized: "Check"), commands: [
                    Command(id: "interference", title: String(localized: "Interference"), symbol: "square.on.square.intersection.dashed",
                            help: String(localized: "Check every pair of parts at this pose")),
                    Command(id: "mass", title: String(localized: "Mass"), symbol: "scalemass",
                            help: String(localized: "Mass properties: total, centre of mass, inertia")),
                ]),
                .init(name: String(localized: "Sweep"), commands: [
                    Command(id: "sweep", title: String(localized: "Sweep Check"), symbol: "waveform.path.ecg.rectangle",
                            help: String(localized: "Interference over the motion study")),
                ]),
            ]
        }
    }

    /// Why a command cannot run for this product, or nil when it can.
    nonisolated static func unavailableReason(_ id: String, product: AssembleModel.Product) -> String? {
        switch id {
        case "dragTip" where product != .arm: String(localized: "For arms: a hand moves with the grasp editor")
        case "grasp" where product != .hand: String(localized: "For hands: the arm's gripper has one joint")
        default: nil
        }
    }

    private func isOn(_ id: String) -> Bool {
        switch id {
        case "select": model.tool == .select
        case "turnJoint": model.tool == .rotateJoint
        case "dragTip": model.tool == .dragTip
        case "grasp": model.tool == .grasp
        default: false
        }
    }

    private func run(_ id: String) {
        switch id {
        case "newArm":
            confirm = ConfirmRequest(title: String(localized: "Replace the assembly with the arm template?"),
                                     message: String(localized: "The six-joint arm template replaces this assembly, with its joints, saved poses and grasps."),
                                     verb: String(localized: "Replace with Arm"), destructive: true) { model.openArm(flow: flow) }
        case "commit": model.commit()
        case "mjcf": export("export_mjcf")
        case "urdf": export("export_urdf")
        case "select": model.tool = .select
        case "turnJoint":
            model.tool = .rotateJoint
            if model.selectedJoint == nil { model.selectedJoint = model.joints.first?.id }
        case "savePose": _ = model.savePose()
        case "dragTip": model.tool = .dragTip
        case "grasp": model.tool = .grasp
        case "motionStudy":
            showBottom()
            if model.study == nil { model.runStudy(thenPlay: true) } else { model.play() }
        case "home": model.pose(named: "home")
        case "interference": model.checkInterference()
        case "mass": model.computeMass()
        case "sweep":
            showBottom()
            model.runStudy()
        default: break
        }
    }

    @ViewBuilder private var posesItems: some View {
        if (model.doc?.poses ?? []).isEmpty { Text("No saved poses") }
        ForEach(model.doc?.poses ?? []) { p in Button(AsmFormat.title(p.id)) { model.pose(named: p.id) } }
    }

    @ViewBuilder private func tool(_ c: Command, labels: Bool) -> some View {
        let reason = Self.unavailableReason(c.id, product: model.product)
        let on = isOn(c.id)
        Group {
            if c.posesMenu {
                Menu { posesItems } label: { label(c.title, c.symbol, labels: labels) }
                    .menuStyle(.vfPlain)
            } else {
                Button { run(c.id) } label: { label(c.title, c.symbol, on: on, labels: labels) }
                    .buttonStyle(.plain)
            }
        }
        .disabled(reason != nil)
        .help(reason ?? c.help)
        .accessibilityLabel(c.title)
        .accessibilityHint(reason ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The commands that did not fit, with the same labels, state and reasons: a disabled
    /// command says why on a second line, a mode shows its checkmark.
    private func more(_ groups: [RibbonFold.Group<Command>]) -> some View {
        Menu {
            ForEach(groups) { g in
                Section(g.name) {
                    ForEach(g.commands) { c in
                        let reason = Self.unavailableReason(c.id, product: model.product)
                        if c.posesMenu {
                            Menu { posesItems } label: { Label(c.title, systemImage: c.symbol) }
                                .disabled(reason != nil)
                        } else if c.mode {
                            Toggle(isOn: Binding(get: { isOn(c.id) }, set: { _ in run(c.id) })) {
                                Label(c.title, systemImage: c.symbol)
                                if let reason { Text(reason) }
                            }
                            .disabled(reason != nil)
                        } else {
                            Button { run(c.id) } label: {
                                Label(c.title, systemImage: c.symbol)
                                if let reason { Text(reason) }
                            }
                            .disabled(reason != nil)
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: VFSpace.xs) {
                Image(systemName: "ellipsis.circle").font(VFFont.glyph(18)).frame(height: 22).accessibilityHidden(true)
                Text("More").textCase(.uppercase).font(VFFont.micro.weight(.semibold)).tracking(0.4).lineLimit(1)
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, VFSpace.s)
            .frame(minWidth: 44, minHeight: 50)
            .contentShape(Rectangle())
        }
        .menuStyle(.vfPlain)
        .help(String(localized: "More commands: \(groups.flatMap(\.commands).map(\.title).joined(separator: ", "))"))
        .accessibilityLabel("More Commands")
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
                Text(c).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
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

    /// A ribbon tool: a big icon over its capitalised name, or the icon alone when the window
    /// is narrow (the name stays in the tooltip and for VoiceOver).
    private func label(_ title: String, _ symbol: String, on: Bool = false, labels: Bool = true) -> some View {
        VStack(spacing: VFSpace.xs) {
            Image(systemName: symbol).font(VFFont.glyph(18)).frame(height: 22).accessibilityHidden(true)
            if labels {
                Text(title).textCase(.uppercase).font(VFFont.micro.weight(.semibold)).tracking(0.4).lineLimit(1)
            }
        }
        .foregroundStyle(on ? theme.accentText : theme.ink)
        .padding(.horizontal, VFSpace.s)
        .frame(minWidth: labels ? 64 : 40, minHeight: labels ? 50 : 40)
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
