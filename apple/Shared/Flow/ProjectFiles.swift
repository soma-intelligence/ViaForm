import Foundation
import SwiftUI

/// The `.viaform` project as one document: the design, the board and the bill of materials
/// (written by the BOM engine) and the pipeline (`flow.json`, written by the flow core). Every
/// Save and Open that touches a project goes through here, so the pipeline is never left
/// behind; a design file (`.sc`) keeps a pipeline of its own as an autosave keyed by its path.
///
/// Save and Open run off the main actor (UI-UX-AUDIT P0-11): the BOM's queue holds the design
/// and board sessions while the engine writes or reads the file, and the pipeline's `flow.json`
/// is written or read by a pipeline handle of its own on a worker. The window shows what runs
/// (`ProjectActivity`) and an Open that fails offers Try Again.
@MainActor
enum ProjectFiles {
    /// The models of a project window.
    struct Context {
        let design: DesignModel
        let pcb: PCBModel
        let bom: BomModel
        let flow: FlowModel
    }

    /// One window's models, held weakly so a closed window frees them, and the revisions last
    /// written or read (the "edited" mark).
    @MainActor
    private final class Entry {
        weak var design: DesignModel?
        weak var pcb: PCBModel?
        weak var bom: BomModel?
        weak var flow: FlowModel?
        var savedDesign: Int
        var savedBoard: Int
        let activity = ProjectActivity()

        init(_ c: Context) {
            design = c.design; pcb = c.pcb; bom = c.bom; flow = c.flow
            savedDesign = c.design.snapshot.revision
            savedBoard = c.pcb.revision
        }

        var context: Context? {
            guard let design, let pcb, let bom, let flow else { return nil }
            return Context(design: design, pcb: pcb, bom: bom, flow: flow)
        }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    /// Every window registers its models when it appears; the File menu, the close and quit
    /// checks and the BOM panel find them by the window's design model.
    static func register(_ c: Context) {
        entries = entries.filter { $0.value.design != nil }
        if entries[ObjectIdentifier(c.design)]?.context == nil {
            entries[ObjectIdentifier(c.design)] = Entry(c)
        }
    }

    static func context(for design: DesignModel) -> Context? { entries[ObjectIdentifier(design)]?.context }

    /// What the window's project files are doing (Saving, Opening), shown over the window.
    static func activity(for design: DesignModel) -> ProjectActivity? { entries[ObjectIdentifier(design)]?.activity }

    /// Every open window's context (quit asks each edited one).
    static var all: [Context] { entries.values.compactMap(\.context) }

    /// The window that last came forward. Kept for code paths that have no model at hand.
    static var current: Context?

    /// The design or the board changed since the last save, open or new.
    static func isEdited(_ c: Context) -> Bool {
        guard let e = entries[ObjectIdentifier(c.design)] else { return c.design.snapshot.dirty }
        return c.design.snapshot.revision != e.savedDesign || c.pcb.revision != e.savedBoard
    }

    /// Marks the window's models as matching what is on disk: their revisions now, or the ones
    /// a save started from (an edit made while it ran stays edited).
    static func markSaved(_ c: Context, design: Int? = nil, board: Int? = nil) {
        guard let e = entries[ObjectIdentifier(c.design)] else { return }
        e.savedDesign = design ?? c.design.snapshot.revision
        e.savedBoard = board ?? c.pcb.revision
    }

    static let projectExtension = "viaform"

    static func isProject(_ url: URL) -> Bool { url.pathExtension.lowercased() == projectExtension }

    /// Writes the project at `url`, then the pipeline into it, off the main actor. False when
    /// the file was not written (the BOM model holds the engine's reason in its message).
    @discardableResult
    static func save(_ url: URL, in c: Context) async -> Bool {
        let activity = activity(for: c.design)
        let revisions = (design: c.design.snapshot.revision, board: c.pcb.revision)
        // The pipeline as it is now, in memory; written into the file on a worker.
        let flowDoc = c.flow.exportDocument()
        let ok = await ActionTiming.measure("project.save", {
            activity?.begin(String(localized: "Saving \(url.lastPathComponent)"))
        }) {
            guard await c.bom.saveProject(url, design: c.design, pcb: c.pcb) else { return false }
            if let flowDoc, let e = await FlowFile.write(flowDoc, into: url) {
                c.bom.say(e, error: true)
                return false
            }
            return true
        }
        activity?.end()
        guard ok else { return false }
        c.flow.adoptSavedProject(url)
        markSaved(c, design: revisions.design, board: revisions.board)
        return true
    }

    /// Opens the project at `url`, off the main actor: design, board and BOM, then its
    /// pipeline. A failure shows over the window with Try Again.
    @discardableResult
    static func open(_ url: URL, in c: Context) async -> Bool {
        let activity = activity(for: c.design)
        let autosave = c.flow.autosaveURL(for: url.path)
        let ok = await ActionTiming.measure("project.open", {
            activity?.begin(String(localized: "Opening \(url.lastPathComponent)"))
        }) { () -> Bool in
            guard await c.bom.openProject(url, design: c.design, pcb: c.pcb) else { return false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let doc = await FlowFile.read(from: url, autosave: autosave)
            c.flow.adoptOpenedProject(url, doc: doc)
            markSaved(c)
            return true
        }
        if ok {
            activity?.end()
        } else {
            activity?.end(failure: c.bom.message ?? String(localized: "\(url.lastPathComponent) could not be opened."),
                          retry: { [weak design = c.design] in
                              guard let design, let c = context(for: design) else { return }
                              Task { await open(url, in: c) }
                          })
        }
        return ok
    }

    /// Opens any file the app reads: a project, a design (its own pipeline comes back with it)
    /// or a file inserted into the open design (the pipeline stays).
    static func open(_ url: URL, design: DesignModel, in c: Context?) {
        let c = c ?? context(for: design)
        if isProject(url), let c {
            let t0 = ActionTiming.now()
            Task { await open(url, in: c) }
            ActionTiming.click("project.open", since: t0)
            return
        }
        design.open(url)
        let ext = url.pathExtension.lowercased()
        if ["sc", "solidcraft"].contains(ext) || !knownInserts.contains(ext) {
            c?.flow.openDocument(url.path)
            if let c { markSaved(c) }
        }
    }

    /// Extensions `DesignModel.open` inserts into the open design rather than opening.
    static let knownInserts: Set<String> = ["step", "stp", "iges", "igs", "3dm", "fcstd", "stl", "obj", "3mf", "ply", "glb", "gltf", "json", "dxf", "svg"]

    /// A new, untitled document: a fresh pipeline too.
    static func newDesign(_ design: DesignModel, in c: Context?) {
        let c = c ?? context(for: design)
        design.newDesign()
        c?.flow.newDocument()
        if let c { markSaved(c) }
    }
}

extension View {
    /// Makes this window's models the ones the File menu acts on while it is frontmost.
    func projectFilesContext(design: DesignModel, pcb: PCBModel, bom: BomModel, flow: FlowModel) -> some View {
        modifier(ProjectFilesContext(context: .init(design: design, pcb: pcb, bom: bom, flow: flow)))
    }
}

private struct ProjectFilesContext: ViewModifier {
    let context: ProjectFiles.Context
    @Environment(\.scenePhase) private var phase
    @State private var activity: ProjectActivity?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let activity { ProjectActivityView(activity: activity) }
            }
            .onAppear {
                ProjectFiles.register(context)
                ProjectFiles.current = context
                activity = ProjectFiles.activity(for: context.design)
            }
            .onChange(of: phase) { _, p in if p == .active { ProjectFiles.current = context } }
    }
}

/// What a window's project files are doing: the running Save or Open, and the last Open that
/// failed with its Try Again.
@MainActor
@Observable
final class ProjectActivity {
    private(set) var busy: String?
    private(set) var failure: String?
    private(set) var retry: (() -> Void)?

    func begin(_ label: String) {
        busy = label
        failure = nil
        retry = nil
    }

    func end(failure: String? = nil, retry: (() -> Void)? = nil) {
        busy = nil
        self.failure = failure
        self.retry = retry
    }

    func dismiss() { failure = nil; retry = nil }
}

/// The busy state over the window (a spinner with its label after 300 ms, so a fast save never
/// flickers) and the failed Open with Try Again.
private struct ProjectActivityView: View {
    let activity: ProjectActivity

    var body: some View {
        VStack(spacing: VFSpace.s) {
            if let busy = activity.busy {
                ProjectBusyPill(label: busy).id(busy)
            }
            if let f = activity.failure {
                ErrorBanner(message: f, retry: activity.retry.map { r in { activity.dismiss(); r() } }, dismiss: { activity.dismiss() })
            }
        }
        .padding(.top, VFSpace.l)
        .padding(.horizontal, VFSpace.l)
    }
}

private struct ProjectBusyPill: View {
    let label: String
    @State private var shown = false

    var body: some View {
        Group {
            if shown {
                DelayedProgress(label: label, delay: .zero)
                    .padding(.horizontal, VFSpace.l)
                    .padding(.vertical, VFSpace.s)
                    .vfSurface(.floating)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            shown = true
        }
        .allowsHitTesting(false)
    }
}

/// The pipeline's `flow.json` inside a `.viaform` file, written and read off the main actor by
/// a pipeline handle of its own (never the window's, which stays on the main actor).
enum FlowFile {
    /// Writes `doc` (the pipeline as `FlowModel.exportDocument` gives it) into the project at
    /// `url`; answers the reason it failed, nil when written.
    static func write(_ doc: Data, into url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let flow = RustFlow()
            let text = String(decoding: doc, as: UTF8.self)
            for command in [#"{"op":"import","doc":"# + text + "}", Self.json(["op": "save", "path": url.path])] {
                if let e = Self.error(flow.command(command)) { return e }
            }
            return nil
        }.value
    }

    /// The pipeline of the project at `url`: its `flow.json`, else the autosave at `autosave`,
    /// else nil (a fresh pipeline).
    static func read(from url: URL, autosave: URL?) async -> Any? {
        await Task.detached(priority: .userInitiated) { () -> Doc? in
            let flow = RustFlow()
            let opened = Self.object(flow.command(Self.json(["op": "open", "path": url.path])))
            if (opened?["found"] as? Bool) == true, let doc = Self.object(flow.query(#"{"op":"export"}"#))?["doc"] {
                return Doc(value: doc)
            }
            guard let autosave, let data = try? Data(contentsOf: autosave), let doc = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return Doc(value: doc)
        }.value?.value
    }

    /// A JSON document handed from the worker to the main actor once (nobody else holds it).
    private struct Doc: @unchecked Sendable { let value: Any }

    private static func json(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func object(_ reply: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
    }

    private static func error(_ reply: String) -> String? { object(reply)?["error"] as? String }
}

/// The one name of the open product, the same in the title bar, the browser root, the inspector
/// and the Touch header: the product the pipeline names, else the design's name.
enum ProjectTitle {
    @MainActor
    static func of(flow: FlowModel, design: DesignModel) -> String {
        let p = flow.product.trimmingCharacters(in: .whitespaces)
        return p.isEmpty || p == "Untitled" ? design.snapshot.name : p
    }
}
