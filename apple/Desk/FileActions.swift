#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Files

/// The File menu's actions for one window. Every action finds the window's models from its design
/// model (`ProjectFiles.context(for:)`), asks before discarding edits, and says when a write fails.
@MainActor
enum FileActions {
    static let openTypes = ["viaform", "sc", "solidcraft", "json", "step", "stp", "iges", "igs", "stl", "obj", "3mf", "dxf", "svg"]

    /// Opens a project (`.viaform`: design, board, BOM and pipeline), a design or a file to
    /// insert into the open design. Asks first when opening would replace edited work.
    static func open(_ model: DesignModel) {
        let p = NSOpenPanel()
        p.allowedContentTypes = openTypes.compactMap { UTType(filenameExtension: $0) }
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let url = p.url else { return }
        open(url, model)
    }

    static func open(_ url: URL, _ model: DesignModel) {
        let replaces = ProjectFiles.isProject(url) || !ProjectFiles.knownInserts.contains(url.pathExtension.lowercased())
        let go = {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            ProjectFiles.open(url, design: model, in: ProjectFiles.context(for: model))
        }
        if replaces { ProjectGuard.confirmDiscard(model, verb: String(localized: "Open")) { go() } } else { go() }
    }

    /// Saves the open project in place, else asks where. Answers whether the file was written.
    @discardableResult
    static func save(_ model: DesignModel) -> Bool {
        let c = ProjectFiles.context(for: model)
        if let c, c.flow.isProjectFile, let key = c.flow.documentKey {
            return report(ProjectFiles.save(URL(fileURLWithPath: key), in: c), c: c, url: URL(fileURLWithPath: key))
        }
        if let path = model.snapshot.path {
            let ok = model.run("file.save", ["path": path]) != nil
            if ok, let c { ProjectFiles.markSaved(c) }
            return report(ok, c: c, url: URL(fileURLWithPath: path), design: model)
        }
        return saveAs(model)
    }

    @discardableResult
    static func saveAs(_ model: DesignModel) -> Bool {
        let c = ProjectFiles.context(for: model)
        let p = NSSavePanel()
        let name = c.map { ProjectTitle.of(flow: $0.flow, design: model) } ?? model.snapshot.name
        p.nameFieldStringValue = name + ".viaform"
        p.allowedContentTypes = ["viaform", "sc"].compactMap { UTType(filenameExtension: $0) }
        p.allowsOtherFileTypes = false
        guard p.runModal() == .OK, let url = p.url else { return false }
        if ProjectFiles.isProject(url), let c {
            return report(ProjectFiles.save(url, in: c), c: c, url: url)
        }
        let ok = model.run("file.save_as", ["path": url.path]) != nil
        if ok, let c {
            c.flow.adoptDocument(url.path)
            ProjectFiles.markSaved(c)
        }
        return report(ok, c: c, url: url, design: model)
    }

    static func newDesign(_ model: DesignModel) {
        ProjectGuard.confirmDiscard(model, verb: String(localized: "New Design")) {
            ProjectFiles.newDesign(model, in: ProjectFiles.context(for: model))
        }
    }

    static func export(_ model: DesignModel) {
        let p = NSSavePanel()
        p.nameFieldStringValue = model.snapshot.name + ".step"
        p.allowedContentTypes = ["step", "stl", "obj", "3mf"].compactMap { UTType(filenameExtension: $0) }
        p.allowsOtherFileTypes = true
        // NSSavePanel asks before replacing an existing file (VIAFORM-SPEC 6.4).
        guard p.runModal() == .OK, let url = p.url else { return }
        let ok = model.run("file.export", ["path": url.path]) != nil
        if ok {
            model.flash(String(localized: "Exported \(url.lastPathComponent)"))
        } else {
            alert(String(localized: "The design could not be exported."),
                  detail: model.message ?? String(localized: "Check that the folder is writable and try again."))
        }
    }

    /// Shows why a save failed and offers Save As; answers `ok`.
    private static func report(_ ok: Bool, c: ProjectFiles.Context?, url: URL, design: DesignModel? = nil) -> Bool {
        guard !ok else {
            (c?.design ?? design)?.flash(String(localized: "Saved \(url.lastPathComponent)"))
            return true
        }
        let reason = c?.bom.message ?? design?.message ?? c?.design.message
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = String(localized: "“\(url.lastPathComponent)” could not be saved.")
        a.informativeText = (reason.map { $0 + "\n\n" } ?? "") + String(localized: "Your work is still open. Try again, or save a copy somewhere else.")
        a.addButton(withTitle: String(localized: "Save As…"))
        a.addButton(withTitle: String(localized: "Cancel"))
        if a.runModal() == .alertFirstButtonReturn, let model = c?.design ?? design {
            return saveAs(model)
        }
        return false
    }

    private static func alert(_ text: String, detail: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = text
        a.informativeText = detail
        a.runModal()
    }
}

// MARK: Unsaved changes

/// Asks before edited work is replaced or closed: Save, Don't Save, Cancel (HIG documents).
@MainActor
enum ProjectGuard {
    /// Runs `proceed` at once when nothing is edited; otherwise asks, saves when asked to, and
    /// runs `proceed` unless the reader cancels or the save fails.
    static func confirmDiscard(_ model: DesignModel, verb: String, proceed: @escaping () -> Void) {
        guard let c = ProjectFiles.context(for: model), ProjectFiles.isEdited(c) else { proceed(); return }
        switch ask(c, verb: verb) {
        case .save: if FileActions.save(model) { proceed() }
        case .discard: proceed()
        case .cancel: break
        }
    }

    enum Answer { case save, discard, cancel }

    static func ask(_ c: ProjectFiles.Context, verb: String) -> Answer {
        let name = ProjectTitle.of(flow: c.flow, design: c.design)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = String(localized: "Do you want to save the changes to “\(name)”?")
        a.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        a.addButton(withTitle: String(localized: "Save"))
        a.addButton(withTitle: String(localized: "Cancel"))
        let dontSave = a.addButton(withTitle: String(localized: "Don't Save"))
        dontSave.hasDestructiveAction = true
        _ = verb
        switch a.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Quit: asks for each edited window in turn. False cancels the quit.
    static func confirmQuit() -> Bool {
        for c in ProjectFiles.all where ProjectFiles.isEdited(c) {
            switch ask(c, verb: String(localized: "Quit")) {
            case .save: if !FileActions.save(c.design) { return false }
            case .discard: continue
            case .cancel: return false
            }
        }
        return true
    }
}

/// The app delegate's quit check (`applicationShouldTerminate`).
final class ViaFormAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { ProjectGuard.confirmQuit() } ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Ties a SwiftUI window to its project: the close button's edited dot, and a Save, Don't Save,
/// Cancel question before an edited window closes (Command-W or the close button).
struct ProjectWindowGuard: NSViewRepresentable {
    let context: ProjectFiles.Context
    let edited: Bool

    func makeNSView(context: Context) -> NSView {
        let v = GuardView()
        v.project = self.context
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let v = v as? GuardView else { return }
        v.project = self.context
        v.window?.isDocumentEdited = edited
    }

    final class GuardView: NSView {
        var project: ProjectFiles.Context?
        private var proxy: CloseProxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, proxy == nil || w.delegate !== proxy else { return }
            let p = CloseProxy(original: w.delegate) { [weak self] in
                guard let c = self?.project, ProjectFiles.isEdited(c) else { return true }
                switch ProjectGuard.ask(c, verb: String(localized: "Close")) {
                case .save: return FileActions.save(c.design)
                case .discard: return true
                case .cancel: return false
                }
            }
            proxy = p
            w.delegate = p
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Answers `windowShouldClose` and forwards every other delegate call to SwiftUI's own delegate.
    final class CloseProxy: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?
        let shouldClose: @MainActor () -> Bool

        init(original: NSWindowDelegate?, shouldClose: @escaping @MainActor () -> Bool) {
            self.original = original
            self.shouldClose = shouldClose
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard MainActor.assumeIsolated({ shouldClose() }) else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to sel: Selector!) -> Bool {
            super.responds(to: sel) || (original?.responds(to: sel) ?? false)
        }

        override func forwardingTarget(for sel: Selector!) -> Any? {
            if let o = original, o.responds(to: sel) { return o }
            return super.forwardingTarget(for: sel)
        }
    }
}
#endif
