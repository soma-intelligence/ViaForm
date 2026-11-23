import SwiftUI

/// The Generate workspace: set up a 3D study (design space, material, goal, limits, and the
/// regions that hold, load, keep out and keep in, placed by number or by dragging them in the
/// preview), run it, compare its candidates coloured by stress, read their analysis, and build
/// the one picked into the design. The Mac and a regular-width iPad keep the setup in a side
/// panel on the right; iPhone opens it in a sheet over the preview, as Simulation does.
///
/// The gallery stills and the camera live in the model, so a return to the stage finds them.
struct GenerateView: View {
    @Environment(\.viaFormTheme) private var palette
    @Bindable var model: GenerateModel
    let design: DesignModel
    let theme: ViewportTheme
    var compact = false
    @State private var scene: GenerateScene?
    @State private var showSheet = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    /// Inspector beside the preview, or in a sheet.
    private var sideBySide: Bool {
        #if os(iOS)
        return !compact || hSize == .regular
        #else
        return true
        #endif
    }

    var body: some View {
        Group {
            if let scene {
                if sideBySide { wide(scene) } else { narrow(scene) }
            } else {
                Color.clear.onAppear {
                    let s = GenerateScene(theme: theme)
                    if let camera = model.camera { s.cameraState = camera }
                    scene = s
                }
            }
        }
        .onDisappear { if let scene { model.camera = scene.cameraState } }
        .onChange(of: model.study) { _, _ in scene?.update(model) }
        .onChange(of: model.selection) { _, _ in scene?.update(model) }
        .onChange(of: model.activeCase) { _, _ in scene?.update(model) }
        .onChange(of: model.display) { _, _ in scene?.update(model) }
        .onChange(of: model.selected) { _, _ in scene?.update(model) }
        .onChange(of: model.liveVersion) { _, _ in scene?.update(model) }
        .onChange(of: model.running) { _, _ in scene?.update(model) }
        .onChange(of: model.previewsVersion) { _, _ in scene?.update(model) }
        .onChange(of: scene == nil) { _, _ in scene?.update(model) }
        .task(id: model.previewsVersion) { model.renderThumbnails(theme: theme) }
        .task(id: model.outcomeVersion) { await model.runMeshChecks() }
        .onChange(of: model.focusVersion) { _, _ in
            if let b = model.focusBox { scene?.fit(b.lo, b.hi) }
        }
        .sheet(item: $model.comparing) { pair in
            CompareSheet(model: model, pair: pair)
        }
        .confirmSheet(Binding(get: { model.stopRequested ? stopRequest : nil },
                              set: { if $0 == nil { model.stopRequested = false } }))
    }

    /// Stopping a run that has solved for a while asks first (FRONTEND-SPEC 6.4): keep the best
    /// design so far (the default), discard the run, or keep it running.
    private var stopRequest: ConfirmRequest {
        ConfirmRequest(
            title: String(localized: "Stop the study?"),
            message: String(localized: "It has been solving for \(readableDuration(model.runAge)). Keep its best design so far as a candidate (not converged), discard the run, or keep it running."),
            verb: String(localized: "Keep Best So Far"),
            destructive: false,
            perform: { model.cancel() },
            alternate: (title: String(localized: "Discard"), perform: { model.discard() }),
            cancel: { model.stopRequested = false },
            cancelTitle: String(localized: "Keep Running"))
    }

    private func wide(_ scene: GenerateScene) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                stage(scene)
                if model.outcome != nil {
                    Divider()
                    OutcomesPanel(model: model)
                        .padding(.vertical, VFSpace.l)
                        .background(palette.panel)
                }
            }
            Divider()
            GenerateInspector(model: model, design: design)
                .frame(width: VFSize.sidePanel)
        }
    }

    private func narrow(_ scene: GenerateScene) -> some View {
        stage(scene)
            .sheet(isPresented: $showSheet) {
                NavigationStack {
                    GenerateInspector(model: model, design: design)
                        .navigationTitle(model.pane.title)
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showSheet = false } }
                        }
                }
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
            }
    }

    /// The preview with its floating controls.
    private func stage(_ scene: GenerateScene) -> some View {
        ZStack {
            Group {
                if model.display == .assembly && model.assemblyLoaded {
                    // The design itself, where the assembly was inserted: its joints move here.
                    MetalViewport(model: design, theme: theme)
                } else {
                    GenerateViewport(model: model, scene: scene)
                }
            }
            .ignoresSafeArea(edges: sideBySide ? [] : .all)
            VStack(spacing: VFSpace.m) {
                HStack(alignment: .top, spacing: VFSpace.m) {
                    if model.running && model.display != .assembly {
                        LiveRunPanel(model: model, compact: !sideBySide)
                            .vfTransition(.opacity)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: VFSpace.m) {
                        HStack(spacing: VFSpace.m) {
                            Picker("Display", selection: $model.display) {
                                ForEach(GenerateModel.Display.allCases.filter { $0 != .assembly || model.assemblyLoaded }, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .vfDisabled(model.outcome == nil && !model.assemblyLoaded,
                                        reason: String(localized: "Run the study to see a result."))
                            VFIconButton("scope", label: String(localized: "Frame the design space")) {
                                if model.display == .assembly { design.zoomToFit() } else { scene.home(model.study) }
                            }
                            .vfSurface(.control, radius: VFRadius.control)
                        }
                        if model.display == .assembly, let p = model.project {
                            AssemblyBadge(model: model, project: p)
                        }
                        if model.display == .result, let i = model.selected, let p = model.previews[safe: i], let s = model.studied {
                            StressLegend(preview: p, study: s, scale: $model.stressScale)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let holder = EngineGate.shared.holder {
                    Label { Text("\(holder)…") } icon: { ProgressView().controlSize(.small) }
                        .font(VFFont.row)
                        .foregroundStyle(palette.ink)
                        .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.m)
                        .vfSurface(.floating, radius: VFRadius.touchCapsule)
                }
                MessageBanner(model: design)
                if let error = model.error, !model.running {
                    ErrorBanner(message: error, retry: model.readiness == nil ? { model.run() } : nil) { model.clearError() }
                }
                if !sideBySide, model.outcome != nil, model.display == .result {
                    CandidateStrip(model: model, order: model.sortedOutcomes, compact: true)
                        .padding(.vertical, VFSpace.m)
                        .vfSurface(.floating)
                }
                GenerateRunBar(model: model, design: design, showSetup: sideBySide ? nil : $showSheet)
            }
            .padding(VFSpace.panelPadding)
        }
    }
}

extension GenerateModel.Display {
    var title: String {
        switch self {
        case .setup: String(localized: "Setup")
        case .result: String(localized: "Result")
        case .assembly: String(localized: "Assembly")
        }
    }
}

extension GenerateModel.Pane {
    var title: String {
        switch self {
        case .project: String(localized: "Project")
        case .study: String(localized: "Study")
        case .regions: String(localized: "Regions")
        case .results: String(localized: "Results")
        case .variants: String(localized: "Variants")
        }
    }
}

// MARK: Run bar

/// Run or Stop, how far the run is, the setup sheet on iPhone, and Build. Esc never stops a run
/// (it clears the selection); Stop asks first when the run has solved for a while.
struct GenerateRunBar: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel
    let design: DesignModel
    var showSetup: Binding<Bool>?

    var body: some View {
        HStack(spacing: VFSpace.l) {
            VStack(alignment: .leading, spacing: VFSpace.xxs) {
                if model.running {
                    Button(role: .destructive) { model.requestStop() } label: {
                        Label(model.stopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                    }
                        .buttonStyle(.vfSecondary(loading: model.stopping))
                        .fixedSize()
                        .vfDisabled(model.stopping, reason: String(localized: "Keeping the best design so far."))
                        .help("Stop the study and keep its best design so far (Command-.). After 30 s it asks first.")
                        .accessibilityHint(Text("Stops the study and keeps its best design so far as a candidate"))
                } else {
                    Button { model.run() } label: { Label("Run", systemImage: model.outcome == nil ? "play.fill" : "arrow.clockwise") }
                        .buttonStyle(.vfPrimary)
                        .fixedSize()
                        .keyboardShortcut("r", modifiers: .command)
                        .vfDisabled(model.readiness != nil, reason: model.readiness ?? "")
                        .help(model.readiness ?? String(localized: "Run the study"))
                }
                if !model.running, model.outcome == nil || model.readiness != nil {
                    Label {
                        Text(model.readinessLine).lineLimit(2)
                    } icon: {
                        Image(systemName: model.readiness == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(model.readiness == nil ? theme.success : theme.warning)
                    }
                    .font(VFFont.micro)
                    .foregroundStyle(theme.inkSecondary)
                    .frame(maxWidth: VFSize.inspector, alignment: .leading)
                }
            }
            if let showSetup {
                VFIconButton("slider.horizontal.3", label: String(localized: "Study setup"), size: 15) { showSetup.wrappedValue = true }
            }
            Divider().frame(height: VFSize.chip)
            status.frame(minWidth: 60, maxWidth: 360, alignment: .leading)
            Divider().frame(height: VFSize.chip)
            Button { model.build(into: design) } label: { Label("Build", systemImage: "hammer.fill") }
                .buttonStyle(.vfSecondary(loading: model.building))
                .fixedSize()
                .vfDisabled(buildBlocked != nil, reason: buildBlocked ?? "")
                .help(buildBlocked ?? String(localized: "Build the picked candidate into the design"))
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .padding(.horizontal, VFSpace.xl).padding(.vertical, VFSpace.m)
        .vfSurface(.control)
    }

    /// Why Build is off, or nil.
    private var buildBlocked: String? {
        if EngineGate.shared.shut { return EngineGate.reason }
        if model.running { return String(localized: "Wait for the study to finish, or stop it.") }
        if model.building { return String(localized: "Building the candidate now.") }
        if model.selected == nil { return String(localized: "Run the study, then pick a candidate.") }
        return nil
    }

    /// "About 40 s left" while the run is inside its estimate; past it, the time so far and
    /// the estimate it ran over, so the text never reads "24 s of about 2 s".
    static func timing(elapsed: Double, expected: Double, lower: Bool = false) -> String {
        if elapsed < expected {
            let left = readableDuration(max(expected - elapsed, 1))
            return lower ? String(localized: "about \(left) left") : String(localized: "About \(left) left")
        }
        let so = readableDuration(elapsed), est = readableDuration(expected)
        return String(localized: "\(so) so far, past the \(est) estimate")
    }

    static func describe(_ p: GenerateJob.Progress) -> String {
        let v = p.variant + 1, n = p.variants
        switch p.stage {
        case "analysing":
            return n > 1 ? String(localized: "Variant \(v) of \(n), checking the shape") : String(localized: "Checking the shape")
        case "done": return String(localized: "Making the surfaces")
        case "starting": return String(localized: "Starting")
        default:
            return n > 1 ? String(localized: "Variant \(v) of \(n), iteration \(p.iteration) of \(p.iterations)")
                : String(localized: "Iteration \(p.iteration) of \(p.iterations)")
        }
    }

    @ViewBuilder private var status: some View {
        Group {
            if model.running, let started = model.startedAt {
                TimelineView(.periodic(from: started, by: 0.5)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(started)
                    VStack(alignment: .leading, spacing: VFSpace.xs) {
                        if let p = model.progress, p.iteration > 0 || p.stage != "optimising" {
                            // The engine's own count: iterations, variants, then the analysis.
                            Text("\(Self.describe(p)), \(Self.timing(elapsed: elapsed, expected: model.expected, lower: true))")
                                .foregroundStyle(theme.inkSecondary)
                                .monospacedDigit()
                            ProgressView(value: min(max(p.fraction, 0), 1))
                                .frame(minWidth: 120)
                                .accessibilityLabel("Study progress")
                        } else {
                            Text(Self.timing(elapsed: elapsed, expected: model.expected))
                                .foregroundStyle(theme.inkSecondary)
                                .monospacedDigit()
                            ProgressView(value: min(elapsed / max(model.expected, 0.1), 0.97))
                                .frame(minWidth: 120)
                                .accessibilityLabel("Study progress")
                        }
                    }
                }
            } else if model.error != nil {
                Label("The run did not finish", systemImage: "xmark.octagon.fill").foregroundStyle(theme.danger)
            } else if let o = model.outcome {
                if model.stale {
                    Text("\(o.candidates.count) candidates in \(readableDuration(o.seconds)), setup changed since")
                        .foregroundStyle(theme.warning)
                } else {
                    Text("\(o.candidates.count) candidates in \(readableDuration(o.seconds))")
                        .foregroundStyle(theme.ink)
                }
            } else if let notice = model.notice {
                Text(notice).foregroundStyle(theme.inkSecondary)
            } else {
                Text("Set up the study, then run").foregroundStyle(theme.inkSecondary)
            }
        }
        .font(VFFont.row)
        .lineLimit(2)
    }
}

// MARK: Gallery

/// The study's candidates side by side, in `order` (by default the engine's); a tap picks one to
/// show, analyse and build. Hovering a card lights its dot in the Pareto chart.
struct CandidateStrip: View {
    @Bindable var model: GenerateModel
    var order: [Int]? = nil
    var compact = false

    var body: some View {
        if let o = model.outcome, let s = model.studied {
            ScrollView(.horizontal) {
                HStack(spacing: VFSpace.l) {
                    ForEach(order ?? Array(o.candidates.indices), id: \.self) { i in
                        let c = o.candidates[i]
                        Button {
                            model.selected = i
                            model.display = .result
                        } label: {
                            CandidateCard(candidate: c, study: s, image: model.thumbnails[i], rendered: model.thumbnailsDone.contains(i),
                                          best: i == o.best, selected: model.selected == i, compact: compact,
                                          checks: model.meshChecks[i], hovered: model.hoveredOutcome == i)
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside { model.hoveredOutcome = i } else if model.hoveredOutcome == i { model.hoveredOutcome = nil }
                        }
                        .accessibilityLabel(Self.label(c, index: i, best: i == o.best))
                        .accessibilityValue(model.meshChecks[i].map { Text($0.summary) } ?? Text(""))
                        .accessibilityAddTraits(model.selected == i ? .isSelected : [])
                    }
                }
                .padding(.horizontal, VFSpace.l)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The card's key numbers, for VoiceOver.
    static func label(_ c: StudyCandidate, index i: Int, best: Bool) -> String {
        let mass = VFFormat.mass(c.massG), sf = formatFactor(c.analysis.safetyFactor)
        let fit = c.feasible ? String(localized: "within the limits") : String(localized: "over a limit")
        let base = best
            ? String(localized: "Candidate \(i + 1), best, \(mass), safety factor \(sf), \(fit)")
            : String(localized: "Candidate \(i + 1), \(mass), safety factor \(sf), \(fit)")
        guard !c.converged else { return base }
        let stop = c.stoppedAt.map { String(localized: "stopped at iteration \($0), not converged") } ?? String(localized: "not converged")
        return base + ", " + stop
    }
}

/// One candidate: its still, whether it keeps the limits, its mass and safety factor.
struct CandidateCard: View {
    @Environment(\.viaFormTheme) private var theme
    let candidate: StudyCandidate
    let study: Study
    let image: CGImage?
    /// The still was attempted (no image then means the surface gave none).
    var rendered = false
    let best: Bool
    let selected: Bool
    var compact = false
    /// The candidate's mesh checks, once run.
    var checks: MeshCheckReport? = nil
    /// Lit from the Pareto chart.
    var hovered = false

    private var width: CGFloat { compact ? 112 : 160 }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 2).resizable().scaledToFill()
                } else if rendered {
                    RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous).fill(theme.well)
                    Image(systemName: "cube.transparent").font(VFFont.glyph(20)).foregroundStyle(theme.inkTertiary)
                } else {
                    SkeletonBlock()
                }
            }
            .frame(width: width, height: width * 0.6875)
            .clipShape(RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous))
            HStack(spacing: VFSpace.xs) {
                Text("#\(candidate.id + 1)").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                if best {
                    Label("Best", systemImage: "star.fill")
                        .labelStyle(.iconOnly)
                        .font(VFFont.micro)
                        .foregroundStyle(theme.accentText)
                        .help("Best candidate")
                }
                Spacer(minLength: VFSpace.xs)
                FeasibleBadge(feasible: candidate.feasible, compact: compact)
            }
            Text("\(VFFormat.mass(candidate.massG)), safety \(formatFactor(candidate.analysis.safetyFactor))")
                .font(VFFont.small)
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(1)
            if !candidate.converged {
                StoppedLine(candidate: candidate, compact: compact)
            }
            if let checks, !compact {
                CheckStatusLabel(status: checks.status, word: checks.summary)
                    .help(checks.items.filter { $0.status == .warning || $0.status == .fail }.map(\.detail).joined(separator: "\n"))
            }
        }
        .frame(width: width)
        .padding(VFSpace.m)
        .background(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous).fill(selected ? theme.selection : (hovered ? theme.ink.opacity(0.06) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous).strokeBorder(selected ? theme.accent : (hovered ? theme.hairline : .clear), lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous))
    }
}

/// Within the limits, or over one: words and a shape, never the colour alone.
struct FeasibleBadge: View {
    @Environment(\.viaFormTheme) private var theme
    let feasible: Bool
    var compact = false

    var body: some View {
        let tint = feasible ? theme.success : theme.warning
        Label(feasible ? String(localized: "Feasible") : String(localized: "Over limit"),
              systemImage: feasible ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .labelStyle(.titleAndIcon)
            .font(VFFont.micro)
            .lineLimit(1)
            .padding(.horizontal, VFSpace.s).padding(.vertical, VFSpace.xxs)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

/// A stopped run's kept design: "Stopped at iteration N" and a "Not converged" badge, in words
/// and a shape, never the colour alone.
struct StoppedLine: View {
    @Environment(\.viaFormTheme) private var theme
    let candidate: StudyCandidate
    var compact = false

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: VFSpace.xxs)) : AnyLayout(HStackLayout(spacing: VFSpace.xs))
        layout {
            if let n = candidate.stoppedAt {
                Text("Stopped at iteration \(n)")
                    .font(VFFont.micro)
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if !compact { Spacer(minLength: 0) }
            NotConvergedBadge()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The badge on a candidate whose optimisation was stopped before it settled.
struct NotConvergedBadge: View {
    @Environment(\.viaFormTheme) private var theme

    var body: some View {
        Label(String(localized: "Not converged"), systemImage: "hourglass.bottomhalf.filled")
            .labelStyle(.titleAndIcon)
            .font(VFFont.micro)
            .lineLimit(1)
            .padding(.horizontal, VFSpace.s).padding(.vertical, VFSpace.xxs)
            .foregroundStyle(theme.warning)
            .background(theme.warning.opacity(0.15), in: Capsule())
            .help("The run was stopped before this design settled. Run again to let it converge.")
            .accessibilityElement(children: .combine)
    }
}

/// A safety factor as read: "2.4", or "∞" when nothing is stressed.
func formatFactor(_ f: Double) -> String {
    guard f.isFinite else { return "∞" }
    return f >= 100 ? String(format: "%.0f", f) : String(format: "%.2g", f)
}

// MARK: Legend

/// The stress colours against the material: the bottom of the scale at nothing, the top at the
/// allowable, with the limit the study holds marked; the scale can be switched.
struct StressLegend: View {
    @Environment(\.viaFormTheme) private var theme
    let preview: PreviewMesh
    let study: Study
    @Binding var scale: StressColors.Scale

    private let barWidth: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            if preview.coloredByStress {
                HStack {
                    Text("Von Mises stress, MPa").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    Spacer(minLength: VFSpace.m)
                    Menu {
                        Picker("Colours", selection: $scale) {
                            ForEach(StressColors.Scale.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "paintpalette").font(VFFont.glyph(12))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Heat map colours")
                    .accessibilityLabel("Heat map colours")
                }
                GeometryReader { g in
                    let allowable = max(study.material.allowable, 1e-9)
                    let x = min(max(study.stressLimit / allowable, 0), 1) * g.size.width
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: VFRadius.mark)
                            .fill(LinearGradient(gradient: StressColors.gradient(scale), startPoint: .leading, endPoint: .trailing))
                        Rectangle().fill(theme.ink).frame(width: 2, height: g.size.height + 6).offset(x: x - 1)
                    }
                }
                .frame(width: barWidth, height: 10)
                .accessibilityHidden(true)
                HStack {
                    Text("0")
                    Spacer()
                    Text("limit \(Int(study.stressLimit.rounded()))")
                    Spacer()
                    Text("\(Int(study.material.allowable.rounded()))")
                }
                .font(VFFont.micro)
                .foregroundStyle(theme.inkSecondary)
                .frame(width: barWidth)
                .accessibilityHidden(true)
                let peak = Double(preview.peakStress)
                if peak > study.stressLimit {
                    Label("Peak \(Int(peak.rounded())) MPa, over the limit", systemImage: "exclamationmark.triangle.fill")
                        .font(VFFont.rowEmphasis)
                        .foregroundStyle(theme.warning)
                } else {
                    Text("Peak \(Int(peak.rounded())) MPa").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                }
            } else {
                Text(preview.voxels ? "Voxels (no surface from the solver)" : "No stress on this surface")
                    .font(VFFont.small)
                    .foregroundStyle(theme.inkSecondary)
            }
        }
        .monospacedDigit()
        .padding(VFSpace.panelPadding)
        .vfSurface(.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Stress legend, 0 to \(Int(study.material.allowable.rounded())) MPa, limit \(Int(study.stressLimit.rounded())) MPa, peak \(Int(Double(preview.peakStress).rounded())) MPa"))
    }
}

/// What the inserted assembly is made of, over its view.
struct AssemblyBadge: View {
    @Environment(\.viaFormTheme) private var theme
    let model: GenerateModel
    let project: GenerateProject

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            Text("\(project.name.capitalized) assembly").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
            if let s = model.assemblySummary {
                Text("\(s.generated) generated parts, \(s.components) real components")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                if let m = s.massG { Text("\(VFFormat.mass(m)) all up").font(VFFont.small).foregroundStyle(theme.inkSecondary) }
            }
            let moving = model.joints.filter(\.movable)
            if !moving.isEmpty {
                Text("\(moving.count) joints. Drive them in the Project pane.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
        }
        .padding(VFSpace.panelPadding)
        .vfSurface(.floating)
    }
}
