import SwiftUI

/// The Project pane: the open project's studies (a tap makes one the setup), its assembly of
/// generated parts and real components, and, once inserted, its joints to drive.
struct ProjectForm: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel
    let design: DesignModel
    @State private var confirm: ConfirmRequest?

    var body: some View {
        let _ = units
        Form {
            Section {
                // The open project is the filled button; the other opens on a click. Only the
                // other is ever disabled (while a study runs), so the open one never reads as off.
                HStack(spacing: VFSpace.m) {
                    ForEach(GenerateProject.samples, id: \.self) { name in
                        ProjectButton(name: name, open: model.project?.name == name, locked: model.running) {
                            if name != model.project?.name { open(name) }
                        }
                    }
                }
            } header: {
                Text("Project")
            } footer: {
                if model.project == nil { Text("Open a sample project: its studies and its assembly load here.") }
            }
            if let p = model.project {
                studies(p)
                assembly(p)
                if model.assemblyLoaded, model.joints.contains(where: \.movable) { joints }
            }
        }
        .formStyle(.grouped)
        .confirmSheet($confirm)
    }

    /// Opens a sample; its first study replaces an edited setup only once confirmed (and the
    /// replacement can be undone).
    private func open(_ name: String) {
        guard model.studyEdited else { model.openSample(name, replaceStudy: true); return }
        confirm = ConfirmRequest(
            title: String(localized: "Replace the current study setup?"),
            message: String(localized: "Opening the \(name.capitalized) project loads its first study over your edits. You can undo this."),
            verb: String(localized: "Replace"),
            destructive: true,
            perform: { model.openSample(name, replaceStudy: true) })
    }

    /// Makes a project study the setup, asking first over an edited one.
    private func pick(_ e: GenerateProject.Entry) {
        let go = {
            model.load(e)
            model.pane = .study
        }
        guard model.studyEdited, model.projectStudy != e.name else { go(); return }
        confirm = ConfirmRequest(
            title: String(localized: "Replace the current study setup?"),
            message: String(localized: "\(e.name) replaces your regions, loads and limits. You can undo this."),
            verb: String(localized: "Replace"),
            destructive: true,
            perform: go)
    }

    private func studies(_ p: GenerateProject) -> some View {
        Section {
            ForEach(p.studies) { e in
                Button { pick(e) } label: {
                    HStack(spacing: VFSpace.m) {
                        Image(systemName: model.projectStudy == e.name ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(model.projectStudy == e.name ? theme.accentText : theme.inkSecondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: VFSpace.xxs) {
                            Text(e.name).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                            Text("\(e.study.elementCount.formatted()) voxels at \(VFFormat.length(e.study.voxel)), \(e.study.material.name)")
                                .font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
                        }
                        Spacer(minLength: VFSpace.xs)
                        if let m = e.result["mass_g"] {
                            Text(VFFormat.mass(m)).font(VFFont.small).monospacedDigit().foregroundStyle(theme.inkSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.projectStudy == e.name ? .isSelected : [])
                .vfDisabled(model.running, reason: String(localized: "Locked while the study runs. Stop to edit."))
            }
        } header: {
            Text("Studies (\(p.studies.count))")
        } footer: {
            Text("Each part is grown around the real components it holds: screw holes, bearing seats and keep-outs come from the component library.")
        }
    }

    private func assembly(_ p: GenerateProject) -> some View {
        Section {
            if let s = model.assemblySummary, p.assembly != nil {
                LabeledContent("Parts", value: "\(s.parts)")
                LabeledContent("Generated", value: "\(s.generated)")
                LabeledContent("Real components", value: String(localized: "\(s.components) placed, \(s.componentRefs.count) lines"))
                if let m = s.massG { LabeledContent("Mass", value: VFFormat.mass(m)) }
                if let q = s.quantitiesMatch {
                    Label(q ? "Quantities match the parts list" : "Quantities differ from the parts list",
                          systemImage: q ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(q ? theme.success : theme.warning)
                        .font(VFFont.small)
                }
                LabeledContent("Movable joints", value: "\(model.joints.filter(\.movable).count)")
                if model.assemblyLoaded {
                    Button { model.display = .assembly } label: { Label("Show the Assembly", systemImage: "cube.transparent") }
                        .buttonStyle(.vfSecondary)
                } else {
                    Button { model.loadAssembly(into: design) } label: { Label("Insert the Assembly", systemImage: "square.stack.3d.down.right") }
                        .buttonStyle(.vfPrimary(loading: model.loadingAssembly))
                        .vfDisabled(EngineGate.shared.shut || model.loadingAssembly,
                                    reason: EngineGate.shared.shut ? EngineGate.reason : String(localized: "Inserting the assembly now."))
                }
            } else {
                EmptyState(String(localized: "No assembly yet"), systemImage: "square.stack.3d.down.right",
                           message: String(localized: "Run the project's studies, then its assembly step."))
            }
        } header: {
            Text("Assembly")
        } footer: {
            Text("One undo step: every part placed, every real component as its own part with its part reference, the base grounded and the joints made.")
        }
    }

    private var joints: some View {
        let groups = Dictionary(grouping: model.joints.filter(\.movable), by: \.group)
        return Group {
            Section {
                HStack {
                    Button { model.closeFist(design: design) } label: { Label("Close Fist", systemImage: "hand.raised.fingers.spread.fill") }
                    Button { model.openHand(design: design) } label: { Label("Open Hand", systemImage: "hand.raised") }
                }
                .buttonStyle(.vfSecondary)
                .vfEngineGate()
            } header: {
                Text("Motion")
            }
            ForEach(groups.keys.sorted(), id: \.self) { g in
                Section(g.capitalized) {
                    ForEach(groups[g] ?? []) { j in
                        JointSlider(joint: j) { model.drive(j.name, to: $0, design: design) }
                    }
                }
            }
        }
    }
}

/// One sample project: filled with the accent when open, in every window state (a system
/// prominent button goes grey in a window that is not key, and read as off).
private struct ProjectButton: View {
    @Environment(\.viaFormTheme) private var theme
    let name: String
    let open: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(name.capitalized, systemImage: name == "hand" ? "hand.raised" : "airplane")
                .font(open ? VFFont.rowEmphasis : VFFont.row)
                .foregroundStyle(open ? theme.onAccent : theme.ink)
                .frame(maxWidth: .infinity, minHeight: max(VFSize.buttonHeight, VFSize.minTarget))
                .background(RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous)
                    .fill(open ? theme.accent : theme.ink.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .vfDisabled(locked && !open, reason: String(localized: "Locked while the study runs. Stop to edit."))
        .opacity(locked && !open ? 0.5 : 1)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// One joint's angle, within its limits.
struct JointSlider: View {
    @ObservedUnits private var units
    let joint: AssemblyJoint
    let set: (Double) -> Void

    var body: some View {
        let _ = units
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            LabeledContent(joint.name) {
                Text(VFFormat.angle(joint.value)).monospacedDigit()
            }
            .font(VFFont.small)
            Slider(value: Binding(get: { joint.value }, set: { set($0) }), in: joint.limits)
                .accessibilityLabel(joint.name)
                .accessibilityValue(VFFormat.angle(joint.value))
        }
    }
}
