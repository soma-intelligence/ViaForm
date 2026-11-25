#if os(macOS)
import AppKit
import SwiftUI

// Document tabs and the File menu in the app bar (gap M-20).
//
// Each project window is one document. Project windows share one native tab group
// (`NSWindow.tabbingMode = .preferred`), so every open design shows as a tab with its name and an
// unsaved `*`, and the tab bar's + makes a new design tab. Open and New Design open a new tab
// when the window already holds work, and reuse a blank window. Save, dirty tracking, recent
// files, the start window and the launch flags stay on FileActions and ProjectFiles.
//
// Not a DocumentGroup: a window owns five models (design, board, BOM, pipeline, study) with
// their own async save, close and quit checks and launch flags; moving them under
// ReferenceFileDocument is a larger change than the tabs need.

/// The tab and window title: the project's name, then `*` while it has unsaved edits.
enum DocTabTitle {
    static let marker = "*"

    static func text(_ name: String, edited: Bool) -> String { edited ? name + marker : name }

    @MainActor static func of(_ c: ProjectFiles.Context) -> String {
        text(ProjectTitle.of(flow: c.flow, design: c.design), edited: ProjectFiles.isEdited(c))
    }
}

@MainActor
enum DocTabs {
    /// The project WindowGroup's id (ViaFormApp) and the tab group every project window joins.
    static let sceneID = "viaform.project"
    static let tabbingID = "viaform.project"

    /// Opens one more project window; set by the first project window from its environment.
    static var openProjectWindow: (() -> Void)?
    /// The window the next new project window joins as a tab.
    private static weak var pendingHost: NSWindow?
    /// A file the next new project window opens.
    private static var pendingOpen: URL?
    /// A project window has been shown: later windows start on a blank design, not the start.
    static private(set) var anyWindowShown = false

    /// Captures (`--window-size`) keep their height: the tab bar is not forced on there.
    private static var forceTabBar: Bool {
        !ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--window-size=") }
    }

    /// A new design in its own tab, next to the key window's.
    static func newTab(from window: NSWindow? = NSApp.keyWindow) {
        guard let open = openProjectWindow else { return }
        pendingHost = window
        open()
    }

    /// The file a new tab was opened for, once.
    static func takePendingOpen() -> URL? {
        defer { pendingOpen = nil }
        return pendingOpen
    }

    /// The window holds nothing yet: no file, no feature, no edit. Open and New reuse it.
    static func isBlank(_ model: DesignModel) -> Bool {
        guard let c = ProjectFiles.context(for: model) else { return model.snapshot.path == nil && model.snapshot.timeline.isEmpty }
        return model.snapshot.path == nil && model.snapshot.timeline.isEmpty && c.flow.documentKey == nil && !ProjectFiles.isEdited(c)
    }

    /// Open and New Design go to a new tab when the window holds work (Fusion), never in the
    /// old single-view layout.
    static func wantsNewTab(_ model: DesignModel) -> Bool {
        openProjectWindow != nil && !DeskLayout.launchLegacy && !isBlank(model)
    }

    /// Opens `url` in a new tab; the new window picks it up when it appears.
    static func openInNewTab(_ url: URL) {
        pendingOpen = url
        newTab()
    }

    /// The marks a design-file save leaves: the ones taken when it started, with the design's
    /// revision moved to now when the engine says the design is clean (writing the file bumps
    /// the revision, so the window would stay edited after Save).
    static func savedMarks(_ before: ProjectFiles.Marks?, _ c: ProjectFiles.Context) -> ProjectFiles.Marks? {
        guard var m = before else { return nil }
        if !c.design.snapshot.dirty { m.design = c.design.snapshot.revision }
        return m
    }

    /// Recent projects and designs, newest first. Read from the list only, never the disk:
    /// the menu body runs on every render, and touching Desktop or Documents files there
    /// would ask for folder access. A file that is gone fails on Open with its reason.
    static func recentURLs(limit: Int = 10) -> [URL] {
        Array(NSDocumentController.shared.recentDocumentURLs.prefix(limit))
    }

    /// Joins `w` to the project tab group, shows the tab bar and gives it a + when SwiftUI
    /// does not already answer `newWindowForTab:`.
    static func adopt(_ w: NSWindow) {
        anyWindowShown = true
        w.tabbingIdentifier = tabbingID
        w.tabbingMode = .preferred
        if let host = pendingHost, host !== w {
            pendingHost = nil
            if !(host.tabbedWindows ?? [host]).contains(w) {
                host.addTabbedWindow(w, ordered: .above)
                w.makeKeyAndOrderFront(nil)
            }
        }
        if NSApp.target(forAction: #selector(NSResponder.newWindowForTab(_:)), to: nil, from: w) == nil {
            let r = NewTabResponder()
            r.nextResponder = w.nextResponder
            w.nextResponder = r
            objc_setAssociatedObject(w, &NewTabResponder.key, r, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if forceTabBar, let g = w.tabGroup, !g.isTabBarVisible { w.toggleTabBar(nil) }
    }
}

/// Answers the tab bar's + with a new design tab.
final class NewTabResponder: NSResponder {
    nonisolated(unsafe) static var key: UInt8 = 0

    override func newWindowForTab(_ sender: Any?) {
        MainActor.assumeIsolated { DocTabs.newTab() }
    }
}

/// Puts the window it sits in into the project tab group, and lends DocTabs the scene's
/// openWindow so menus and the + can open new tabs.
struct DocTabHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HostView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let open = context.environment.openWindow
        DocTabs.openProjectWindow = { open(id: DocTabs.sceneID) }
    }

    final class HostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            // After SwiftUI has ordered the window in, so the tab group exists.
            DispatchQueue.main.async { DocTabs.adopt(w) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: App bar File menu

/// The app bar's File menu (Fusion's file menu): New Design, New Design Tab, Open, Open Recent,
/// Save, Save As, Export. Each item goes through FileActions, as the menu bar's File menu does.
struct AppBarFileMenu: View {
    let model: DesignModel

    var body: some View {
        let shut = EngineGate.shared.shut
        Menu {
            Button("New Design") { FileActions.newDesign(model) }.disabled(shut)
            Button("New Design Tab") { DocTabs.newTab() }.disabled(shut || DocTabs.openProjectWindow == nil)
            Divider()
            Button("Open\u{2026}") { FileActions.open(model) }.disabled(shut)
            RecentFilesMenu(model: model)
            Divider()
            Button("Save") { FileActions.save(model) }.disabled(shut)
            Button("Save As\u{2026}") { FileActions.saveAs(model) }.disabled(shut)
            Divider()
            Button("Export\u{2026}") { FileActions.export(model) }.disabled(shut)
        } label: {
            Label("File", systemImage: "doc")
        }
        .help("File: new, open, recent, save and export")
    }
}

/// Open Recent: the recent projects and designs, then Clear Menu.
struct RecentFilesMenu: View {
    let model: DesignModel?

    var body: some View {
        let urls = DocTabs.recentURLs()
        Menu("Open Recent") {
            ForEach(urls, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) {
                    if let model { FileActions.open(url, model) }
                }
                .help(url.path)
            }
            if !urls.isEmpty { Divider() }
            Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
                .disabled(urls.isEmpty)
        }
        .disabled(model == nil || EngineGate.shared.shut)
    }
}

/// Save in the app bar, greyed out while nothing is unsaved.
struct AppBarSaveButton: View {
    let model: DesignModel
    let edited: Bool

    var body: some View {
        Button { FileActions.save(model) } label: { Label("Save", systemImage: "square.and.arrow.down") }
            .vfDisabled(!edited || EngineGate.shared.shut,
                        reason: EngineGate.shared.shut ? EngineGate.reason : String(localized: "Nothing to save."))
            .help("Save (Command-S)")
    }
}

// MARK: Self test

/// Checks for M-20 and the Mac wiring of the extra sketch tools (B-11). Runs real engine
/// commands through DesignModel. `--selftest-mac-docs` runs it alone and quits.
enum MacDocsSelfTest {
    @MainActor static func runIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("--selftest-mac-docs") else { return }
        let r = checks()
        for (ok, name) in r { print("\(ok ? "PASS" : "FAIL") \(name)") }
        print("mac-docs \(r.filter(\.0).count)/\(r.count) passed")
        fflush(stdout)
        exit(r.allSatisfy(\.0) ? 0 : 1)
    }

    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        out.append((DocTabTitle.text("Bracket", edited: true) == "Bracket*" && DocTabTitle.text("Bracket", edited: false) == "Bracket",
                    "M-20 the tab title carries * only while unsaved"))

        // A window's project: edit, then save to a temp file the way File > Save writes a design.
        let m = DesignModel()
        m.run("file.new", quiet: true)
        let c = ProjectFiles.Context(design: m, pcb: PCBModel(sample: false), bom: BomModel(), flow: FlowModel())
        ProjectFiles.register(c)
        ProjectFiles.markSaved(c)
        let fresh = DocTabTitle.of(c)
        out.append((!fresh.hasSuffix(DocTabTitle.marker), "M-20 a new design's tab has no unsaved marker (\(fresh))"))
        out.append((DocTabs.isBlank(m), "M-20 a new design is blank, so Open and New reuse its tab"))
        m.run("solid.box", ["length": 30, "width": 20, "height": 10])
        let edited = DocTabTitle.of(c)
        out.append((edited.hasSuffix(DocTabTitle.marker), "M-20 the tab title shows * after an edit (\(edited))"))
        out.append((!DocTabs.isBlank(m), "M-20 an edited design is not blank, so Open goes to a new tab"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("viaform-docs-selftest-\(UUID().uuidString).sc")
        let marks = ProjectFiles.marks(c)
        let wrote = m.run("file.save", ["path": url.path]) != nil
        if wrote { ProjectFiles.markSaved(c, at: DocTabs.savedMarks(marks, c)) }
        let saved = DocTabTitle.of(c)
        out.append((wrote && FileManager.default.fileExists(atPath: url.path) && !saved.hasSuffix(DocTabTitle.marker),
                    "M-20 saving to a temp file clears the * (\(saved))"))
        try? FileManager.default.removeItem(at: url)

        // B-11: every extra sketch tool is in the sketch tab's ribbon and arms its tool.
        let s = DesignModel()
        s.run("file.new", quiet: true)
        s.startSketch("XY")
        let panels = StageRibbon.panels(tab: "SKETCH", commands: s.commands)
        var missing: [String] = []
        var unarmed: [String] = []
        for t in Tool.moreSketchTools {
            guard let id = t.commandID, let p = panels.first(where: { $0.commands.contains { $0.id == id } }),
                  let info = p.commands.first(where: { $0.id == id }) else { missing.append(t.label); continue }
            CommandRouter.run(info, s)
            if s.tool != t { unarmed.append(t.label) }
            s.tool = .select
        }
        out.append((missing.isEmpty, "B-11 every extra sketch tool is in the sketch ribbon (missing \(missing))"))
        out.append((unarmed.isEmpty && s.sketchOpen, "B-11 each extra sketch tool's ribbon entry arms its tool (not armed \(unarmed))"))
        let extend = panels.first { $0.commands.contains { $0.id == Tool.extend.commandID } }?.name.uppercased()
        let ellipse = panels.first { $0.commands.contains { $0.id == Tool.ellipse.commandID } }?.name.uppercased()
        out.append((extend == SketchRibbonTools.modifyPanel && ellipse == SketchRibbonTools.createPanel,
                    "B-11 Extend sits in MODIFY, Ellipse in CREATE (\(extend ?? "-"), \(ellipse ?? "-"))"))
        // The CREATE dropdown in the reference's order: Line, Rectangle >, Circle >, ...,
        // Ellipse, ..., Mirror, Circular Pattern, Rectangular Pattern, Project / Include.
        if let create = panels.first(where: { $0.name.uppercased() == SketchRibbonTools.createPanel }),
           let entries = SketchRibbonTools.entries(create) {
            let flat = entries.map { e -> String in
                switch e {
                case .command(let c): c.id
                case .submenu(let t, _): t
                }
            }
            func at(_ x: String) -> Int { flat.firstIndex(of: x) ?? -1 }
            let rect = entries.first { if case .submenu(_, let cs) = $0 { return cs.contains { $0.id == "sketch.rectangle.three_point" } }; return false }
            let circ = entries.first { if case .submenu(_, let cs) = $0 { return cs.map(\.id).starts(with: ["sketch.circle.center", "sketch.circle.two_point", "sketch.circle.three_point"]) }; return false }
            let order = [at("sketch.line"), at("sketch.ellipse"), at("sketch.mirror"), at("sketch.pattern.circular"), at("sketch.pattern.rectangular")]
            out.append((flat.first == "sketch.line" && rect != nil && circ != nil && !order.contains(-1) && order == order.sorted(),
                        "B-11 sketch CREATE follows the reference order with Rectangle and Circle submenus (\(flat))"))
        } else {
            out.append((false, "B-11 the sketch tab has a CREATE panel"))
        }
        out.append((UserDefaults.standard.object(forKey: SolidWorksExtras.storageKey) == nil ? !SolidWorksExtras.on : true,
                    "SolidWorks extras (confirmation corner, S bar) are off by default"))

        s.tool = .sketchMirror
        let hint = SketchRibbonTools.hint(s)
        out.append((hint != nil && SketchRibbonTools.toolDoneShown(s), "B-11 an armed Mirror shows its prompt and a Done (\(hint ?? "-"))"))
        s.tool = .ellipse
        out.append((SketchRibbonTools.hint(s) != nil, "B-11 an armed Ellipse shows its prompt in the status bar"))
        s.tool = .line
        s.endChain()
        out.append((s.tool == .line && s.sketchOpen, "B-11 Done on a line chain ends the chain, keeps the tool and the sketch"))
        return out
    }
}
#endif
