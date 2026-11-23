import Foundation
import SwiftUI

/// The `.viaform` project as one document: the design, the board and the bill of materials
/// (written by the BOM engine) and the pipeline (`flow.json`, written by the flow core). Every
/// Save and Open that touches a project goes through here, so the pipeline is never left
/// behind; a design file (`.sc`) keeps a pipeline of its own as an autosave keyed by its path.
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
    private final class Entry {
        weak var design: DesignModel?
        weak var pcb: PCBModel?
        weak var bom: BomModel?
        weak var flow: FlowModel?
        var savedDesign: Int
        var savedBoard: Int

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

    /// Every open window's context (quit asks each edited one).
    static var all: [Context] { entries.values.compactMap(\.context) }

    /// The window that last came forward. Kept for code paths that have no model at hand.
    static var current: Context?

    /// The design or the board changed since the last save, open or new.
    static func isEdited(_ c: Context) -> Bool {
        guard let e = entries[ObjectIdentifier(c.design)] else { return c.design.snapshot.dirty }
        return c.design.snapshot.revision != e.savedDesign || c.pcb.revision != e.savedBoard
    }

    /// Marks the window's models as matching what is on disk.
    static func markSaved(_ c: Context) {
        guard let e = entries[ObjectIdentifier(c.design)] else { return }
        e.savedDesign = c.design.snapshot.revision
        e.savedBoard = c.pcb.revision
    }

    static let projectExtension = "viaform"

    static func isProject(_ url: URL) -> Bool { url.pathExtension.lowercased() == projectExtension }

    /// Writes the project at `url`, then the pipeline into it. False when the file was not written
    /// (the BOM model holds the engine's reason in its message).
    @discardableResult
    static func save(_ url: URL, in c: Context) -> Bool {
        guard c.bom.saveProject(url, design: c.design, pcb: c.pcb) else { return false }
        c.flow.saveProject(url)
        markSaved(c)
        return true
    }

    /// Opens the project at `url`: design, board and BOM, then its pipeline.
    @discardableResult
    static func open(_ url: URL, in c: Context) -> Bool {
        guard c.bom.openProject(url, design: c.design, pcb: c.pcb) else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        c.flow.openProject(url)
        markSaved(c)
        return true
    }

    /// Opens any file the app reads: a project, a design (its own pipeline comes back with it)
    /// or a file inserted into the open design (the pipeline stays).
    static func open(_ url: URL, design: DesignModel, in c: Context?) {
        let c = c ?? context(for: design)
        if isProject(url), let c { open(url, in: c); return }
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

    func body(content: Content) -> some View {
        content
            .onAppear { ProjectFiles.register(context); ProjectFiles.current = context }
            .onChange(of: phase) { _, p in if p == .active { ProjectFiles.current = context } }
    }
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
