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

    /// The window that last came forward (the menu commands act on it).
    static var current: Context?

    static let projectExtension = "viaform"

    static func isProject(_ url: URL) -> Bool { url.pathExtension.lowercased() == projectExtension }

    /// Writes the project at `url`, then the pipeline into it.
    @discardableResult
    static func save(_ url: URL, in c: Context) -> Bool {
        let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        c.bom.saveProject(url, design: c.design, pcb: c.pcb)
        let after = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard let after, after != before else { return false }
        c.flow.saveProject(url)
        return true
    }

    /// Opens the project at `url`: design, board and BOM, then its pipeline.
    static func open(_ url: URL, in c: Context) {
        c.bom.openProject(url, design: c.design, pcb: c.pcb)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        c.flow.openProject(url)
    }

    /// Opens any file the app reads: a project, a design (its own pipeline comes back with it)
    /// or a file inserted into the open design (the pipeline stays).
    static func open(_ url: URL, design: DesignModel, in c: Context?) {
        if isProject(url), let c { open(url, in: c); return }
        design.open(url)
        let ext = url.pathExtension.lowercased()
        if ["sc", "solidcraft"].contains(ext) || !knownInserts.contains(ext) {
            c?.flow.openDocument(url.path)
        }
    }

    /// Extensions `DesignModel.open` inserts into the open design rather than opening.
    static let knownInserts: Set<String> = ["step", "stp", "iges", "igs", "3dm", "fcstd", "stl", "obj", "3mf", "ply", "glb", "gltf", "json", "dxf", "svg"]

    /// A new, untitled document: a fresh pipeline too.
    static func newDesign(_ design: DesignModel, in c: Context?) {
        design.newDesign()
        c?.flow.newDocument()
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
            .onAppear { ProjectFiles.current = context }
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
