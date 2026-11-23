import SwiftUI

/// The Project pane: the open project's studies (a tap makes one the setup), its assembly of
/// generated parts and real components, and, once inserted, its joints to drive.
struct ProjectForm: View {
    @Bindable var model: GenerateModel
    let design: DesignModel

    var body: some View {
        Form {
            Section {
                // The open project is the filled button; the other opens on a click. Only the
                // other is ever disabled (while a study runs), so the open one never reads as off.
                HStack(spacing: 8) {
                    ForEach(GenerateProject.samples, id: \.self) { name in
                        ProjectButton(name: name, open: model.project?.name == name, locked: model.running) {
                            if name != model.project?.name { model.openSample(name) }
                        }
                    }
                }
                if let p = model.project {
                    LabeledContent("Folder") {
                        Text("docs/generative/\(p.name)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            } header: {
                Text("Project")
            } footer: {
                if model.project == nil { Text("Open a sample: its studies and its assembly come from docs/generative.") }
            }
            if let p = model.project {
                studies(p)
                assembly(p)
                if model.assemblyLoaded, model.joints.contains(where: \.movable) { joints }
            }
        }
        .formStyle(.grouped)
    }

    private func studies(_ p: GenerateProject) -> some View {
        Section {
            ForEach(p.studies) { e in
                Button {
                    model.load(e)
                    model.pane = .study
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.projectStudy == e.name ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(model.projectStudy == e.name ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.callout.weight(.medium))
                            Text("\(e.study.elementCount.formatted()) voxels at \(e.study.voxel.formatted(.number.precision(.fractionLength(0...2)))) mm · \(e.study.material.name)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let m = e.result["mass_g"] {
                            Text(String(format: "%.1f g", m)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.running)
            }
        } header: {
            Text("Studies (\(p.studies.count))")
        } footer: {
            Text("Each part is grown around the real components it holds: screw holes, bearing seats and keep-outs come from docs/components.")
        }
    }

    private func assembly(_ p: GenerateProject) -> some View {
        Section {
            if let s = model.assemblySummary, p.assembly != nil {
                LabeledContent("Parts", value: "\(s.parts)")
                LabeledContent("Generated", value: "\(s.generated)")
                LabeledContent("Real components", value: "\(s.components) placed, \(s.componentRefs.count) lines")
                if let m = s.massG { LabeledContent("Mass", value: String(format: "%.1f g", m)) }
                if let q = s.quantitiesMatch {
                    Label(q ? "Quantities match the component file" : "Quantities differ from the component file",
                          systemImage: q ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(q ? .green : .orange)
                        .font(.caption)
                }
                LabeledContent("Movable joints", value: "\(model.joints.filter(\.movable).count)")
                if model.assemblyLoaded {
                    Button { model.display = .assembly } label: { Label("Show the assembly", systemImage: "cube.transparent") }
                } else {
                    Button { model.loadAssembly(into: design) } label: {
                        if model.loadingAssembly { ProgressView().controlSize(.small) } else { Label("Insert the assembly", systemImage: "square.stack.3d.down.right") }
                    }
                    .disabled(model.loadingAssembly || EngineGate.shared.shut)
                }
            } else {
                Text("No assembly.json yet: run the project's studies, then its assembly step.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Assembly")
        } footer: {
            Text("One undo step: every part placed, every real component as its own part with its component_ref, the base grounded and the joints made.")
        }
    }

    private var joints: some View {
        let groups = Dictionary(grouping: model.joints.filter(\.movable), by: \.group)
        return Group {
            Section {
                HStack {
                    Button { model.closeFist(design: design) } label: { Label("Close fist", systemImage: "hand.raised.fingers.spread.fill") }
                    Button { model.openHand(design: design) } label: { Label("Open", systemImage: "hand.raised") }
                }
                .buttonStyle(.bordered)
                .disabled(EngineGate.shared.shut)
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
    let name: String
    let open: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(name.capitalized, systemImage: name == "hand" ? "hand.raised" : "airplane")
                .font(.body.weight(open ? .semibold : .regular))
                .foregroundStyle(open ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(open ? Color.accentColor : Color.secondary.opacity(0.14)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked && !open)
        .opacity(locked && !open ? 0.5 : 1)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// One joint's angle, within its limits.
struct JointSlider: View {
    let joint: AssemblyJoint
    let set: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(joint.name) {
                Text(String(format: "%.0f°", joint.value)).monospacedDigit()
            }
            .font(.caption)
            Slider(value: Binding(get: { joint.value }, set: set), in: joint.limits)
                .accessibilityLabel(joint.name)
        }
    }
}
