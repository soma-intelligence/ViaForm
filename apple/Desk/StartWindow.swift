#if os(macOS)
import AppKit
import SwiftUI

/// The project start (VIAFORM-SPEC 7.0): new blank design or board, recent projects, the
/// templates (the product presets the core knows: drone, hand, and arm once it exists), and the
/// "Describe what you want to build" field the design agent will answer. Shown when the app opens
/// with nothing to show, from File > New from Template (Shift-Command-N) and with `--start`.
/// Everything here works offline.
struct StartWindow: View {
    @Environment(\.viaFormTheme) private var theme
    /// Runs a template or a blank start, then closes the start.
    let start: (StartTemplate) -> Void
    /// Opens a recent project, or the open panel when nil.
    let open: (URL?) -> Void
    @State private var filter: StartTemplate.Kind?
    @State private var hovered: String?
    @State private var templates: [StartTemplate] = StartTemplate.available()
    @State private var recents: [URL] = StartWindow.recentURLs()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
                .background(theme.chrome)
            VFHairline(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: VFSpace.xxl) {
                    promptRow
                    VStack(alignment: .leading, spacing: VFSpace.l) {
                        Text("Templates").font(VFFont.heading).foregroundStyle(theme.ink)
                        chips
                        grid
                    }
                }
                .padding(VFSpace.xxl)
            }
            .background(theme.panel)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: VFSpace.l) {
            Text("New").font(VFFont.title).foregroundStyle(theme.ink)
            newButton("Blank design", symbol: "cube") { start(.blankPart) }
            newButton("Blank board", symbol: "cpu") { start(.blankBoard) }
            VFHairline().padding(.vertical, VFSpace.s)
            Text("Recent").font(VFFont.title).foregroundStyle(theme.ink)
            if recents.isEmpty {
                Text("Projects you open or save show here.")
                    .font(VFFont.row).foregroundStyle(theme.inkSecondary)
            }
            ForEach(recents, id: \.self) { url in recentRow(url) }
            Button("Open\u{2026}") { open(nil) }
                .buttonStyle(.borderless)
                .font(VFFont.row)
                .keyboardShortcut("o", modifiers: .command)
            Spacer()
        }
        .padding(VFSpace.xl)
    }

    private func newButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: VFSpace.l) {
                Image(systemName: symbol).font(VFFont.glyph(20)).foregroundStyle(theme.accentText).frame(width: 28).accessibilityHidden(true)
                Text(title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(VFFont.glyph(11, weight: .semibold)).foregroundStyle(theme.inkTertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, VFSpace.l)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: VFRadius.card).fill(hovered == title ? theme.well : theme.panel))
            .overlay(RoundedRectangle(cornerRadius: VFRadius.card).strokeBorder(theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? title : (hovered == title ? nil : hovered) }
    }

    private func recentRow(_ url: URL) -> some View {
        let name = url.deletingPathExtension().lastPathComponent
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return Button { open(url) } label: {
            HStack(spacing: VFSpace.l) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(VFFont.row).foregroundStyle(theme.ink).lineLimit(1)
                    Text(date.map { "\(Self.kind(url)) \u{00B7} \(Self.relative($0))" } ?? Self.kind(url))
                        .font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                        .help(date.map { $0.formatted(date: .long, time: .shortened) } ?? "")
                }
                Spacer()
                Image(systemName: "chevron.right").font(VFFont.glyph(11, weight: .semibold)).foregroundStyle(theme.inkTertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, VFSpace.m)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: VFRadius.card).fill(hovered == url.path ? theme.well : theme.panel))
            .overlay(RoundedRectangle(cornerRadius: VFRadius.card).strokeBorder(theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? url.path : (hovered == url.path ? nil : hovered) }
        .help(url.path)
    }

    // MARK: Prompt

    /// The design agent (VIAFORM-SPEC 8.3, phase 8) is not in this build: the field shows what is
    /// coming, disabled, so it never takes text it cannot answer.
    private var promptRow: some View {
        HStack(spacing: VFSpace.l) {
            Image(systemName: "sparkles").font(VFFont.glyph(20)).foregroundStyle(theme.inkTertiary).accessibilityHidden(true)
            Text("Describe what you want to build").font(VFFont.title.weight(.regular)).foregroundStyle(theme.inkTertiary)
            Spacer()
            Text("Coming soon")
                .font(VFFont.caps)
                .foregroundStyle(theme.inkSecondary)
                .padding(.horizontal, VFSpace.m).padding(.vertical, VFSpace.xxs + 1)
                .background(Capsule().fill(theme.well))
                .overlay(Capsule().strokeBorder(theme.hairline))
        }
        .padding(.horizontal, VFSpace.xl)
        .frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: VFRadius.floating).fill(theme.chrome.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: VFRadius.floating).strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Describe what you want to build. Coming soon: the design agent is not in this version.")
        .help("Coming soon: the design agent is not in this version. Start from a template or a blank design.")
    }

    // MARK: Templates

    /// "All" and one chip per kind that has templates: a chip never opens an empty grid.
    private var chips: some View {
        let kinds = StartTemplate.Kind.allCases.filter { k in templates.contains { $0.kind == k } }
        return HStack(spacing: VFSpace.s) {
            chip(nil, String(localized: "All"))
            ForEach(kinds, id: \.self) { k in chip(k, k.title) }
        }
    }

    private func chip(_ k: StartTemplate.Kind?, _ title: String) -> some View {
        let on = filter == k
        return Button { filter = k } label: {
            Text(title).font(VFFont.row.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? theme.onAccent : theme.ink)
                .padding(.horizontal, VFSpace.l)
                .frame(height: 28)
                .background(Capsule().fill(on ? theme.accent : theme.chrome))
                .overlay(Capsule().strokeBorder(on ? .clear : theme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var grid: some View {
        let shown = templates.filter { filter == nil || $0.kind == filter }
        return Group {
            if shown.isEmpty {
                EmptyState(String(localized: "No templates of this kind yet"), systemImage: "square.grid.2x2",
                           message: String(localized: "Start from a blank design or board."),
                           actionTitle: String(localized: "Show All")) { filter = nil }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: VFSpace.l)], alignment: .leading, spacing: VFSpace.l) {
                    ForEach(shown) { t in card(t) }
                }
            }
        }
    }

    private func card(_ t: StartTemplate) -> some View {
        Button { start(t) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    LinearGradient(colors: [Color(vf: theme.palette.viewportTop), Color(vf: theme.palette.viewportBottom)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: t.symbol)
                        .font(VFFont.glyph(54, weight: .light))
                        .accessibilityHidden(true)
                        .foregroundStyle(theme.stageFill(t.tone))
                }
                .frame(height: 140)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    Text(t.detail).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                    VFCaption(t.kind.title).padding(.top, 2)
                }
                .padding(VFSpace.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.chrome)
            .clipShape(RoundedRectangle(cornerRadius: VFRadius.floating))
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.floating)
                    .strokeBorder(hovered == t.id ? theme.accent : theme.hairline, lineWidth: hovered == t.id ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? t.id : (hovered == t.id ? nil : hovered) }
        .accessibilityLabel(Text("\(t.title), \(t.kind.title) template"))
        .accessibilityHint(Text(t.detail))
    }

    // MARK: Recents

    static func recentURLs() -> [URL] {
        NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(6).map { $0 }
    }

    private static func kind(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "viaform": String(localized: "Project")
        case "sc", "solidcraft": String(localized: "Design")
        case "kicad_pcb", "vfpcb": String(localized: "Board")
        default: url.pathExtension.uppercased()
        }
    }

    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// One way to start a project.
struct StartTemplate: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case part, board, product, robot, importFile
        var title: String {
            switch self {
            case .part: String(localized: "Part")
            case .board: String(localized: "Board")
            case .product: String(localized: "Product")
            case .robot: String(localized: "Robot")
            case .importFile: String(localized: "Import")
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let kind: Kind
    let symbol: String
    let tone: VFStage
    /// The core graph preset ("drone", "hand", "arm"), nil for a blank start.
    var preset: String?
    /// The product name the template opens as.
    var product: String?
    /// The stage it opens on.
    var stage: Workspace = .design

    static let blankPart = StartTemplate(id: "blank.part", title: "Blank part", detail: "One body, the full pipeline", kind: .part,
                                         symbol: "cube", tone: .design)
    static let blankBoard = StartTemplate(id: "blank.board", title: "Electronics board", detail: "Schematic and PCB", kind: .board,
                                          symbol: "cpu", tone: .electronics, stage: .electronics)
    static let importFile = StartTemplate(id: "import", title: "Import STEP or KiCad", detail: "Open a file as a new project", kind: .importFile,
                                          symbol: "square.and.arrow.down.on.square", tone: .make)

    /// The product templates, one per core preset, in the order a builder meets them.
    private static let products: [StartTemplate] = [
        StartTemplate(id: "arm", title: "Desk robot arm", detail: "6 joints, gripper, pick policy", kind: .robot,
                      symbol: "figure.arms.open", tone: .robot, preset: "arm", product: "Desk Arm"),
        StartTemplate(id: "drone", title: "FPV drone 3 inch", detail: "Generated frame, flight controller", kind: .robot,
                      symbol: "airplane", tone: .simulate, preset: "drone", product: "Racer 3in"),
        StartTemplate(id: "hand", title: "Robotic hand", detail: "Five fingers, servo board, grasp policy", kind: .robot,
                      symbol: "hand.raised", tone: .assemble, preset: "hand", product: "Humanoid Hand"),
    ]

    /// What the start lists: blank part and board, the presets the core has, import.
    static func available(presets: [String: Int] = RustFlow.presets(products.compactMap(\.preset))) -> [StartTemplate] {
        [blankPart, blankBoard] + products.filter { $0.preset.map { presets[$0] != nil } ?? false } + [importFile]
    }
}
#endif
