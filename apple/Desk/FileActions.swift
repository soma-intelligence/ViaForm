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
        // M-20: a project or design opens in its own tab when this window already holds work.
        if replaces && DocTabs.wantsNewTab(model) {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            DocTabs.openInNewTab(url)
            return
        }
        let go = {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            ProjectFiles.open(url, design: model, in: ProjectFiles.context(for: model))
        }
        if replaces { ProjectGuard.confirmDiscard(model, verb: String(localized: "Open")) { go() } } else { go() }
    }

    /// Saves the open project in place, else asks where. The write runs off the main actor
    /// (UI-UX-AUDIT P0-11); `done` hears whether the file was written, after a failed save's
    /// alert and its Save As.
    static func save(_ model: DesignModel, then done: ((Bool) -> Void)? = nil) {
        let t0 = ActionTiming.now()
        defer { ActionTiming.click("file.save", since: t0) }
        let c = ProjectFiles.context(for: model)
        if let c, c.flow.isProjectFile, let key = c.flow.documentKey {
            write(URL(fileURLWithPath: key), model, command: nil, then: done)
            return
        }
        if let path = model.snapshot.path {
            write(URL(fileURLWithPath: path), model, command: "file.save", then: done)
            return
        }
        saveAs(model, then: done)
    }

    /// Writes `url` off the main actor: the project (`command` nil), else the design file with
    /// `command`. A failure says why and offers Try Again, Save As or Cancel (P0-4).
    private static func write(_ url: URL, _ model: DesignModel, command: String?, then done: ((Bool) -> Void)?) {
        let c = ProjectFiles.context(for: model)
        Task {
            let ok: Bool
            if command == nil, let c {
                ok = await ProjectFiles.save(url, in: c)
            } else {
                let marks = c.flatMap(ProjectFiles.marks)
                ok = await saveDesign(model, command ?? "file.save", path: url.path)
                if ok, let c {
                    if command == "file.save_as" { c.flow.adoptDocument(url.path) }
                    ProjectFiles.markSaved(c, at: DocTabs.savedMarks(marks, c))
                }
            }
            report(ok, c: c, url: url, design: model, again: { write(url, model, command: command, then: done) }, then: done)
        }
    }

    static func saveAs(_ model: DesignModel, then done: ((Bool) -> Void)? = nil) {
        let c = ProjectFiles.context(for: model)
        let p = NSSavePanel()
        let name = c.map { ProjectTitle.of(flow: $0.flow, design: model) } ?? model.snapshot.name
        p.nameFieldStringValue = name + ".viaform"
        p.allowedContentTypes = ["viaform", "sc"].compactMap { UTType(filenameExtension: $0) }
        p.allowsOtherFileTypes = false
        guard p.runModal() == .OK, let url = p.url else { done?(false); return }
        let t0 = ActionTiming.now()
        defer { ActionTiming.click("file.save", since: t0) }
        write(url, model, command: ProjectFiles.isProject(url) && c != nil ? nil : "file.save_as", then: done)
    }

    /// Writes the design file (`.sc`) on a worker: the design engine holds its own lock, so the
    /// main actor only waits if it touches the design meanwhile. The snapshot (path, edited
    /// mark) is read again on the main actor after.
    private static func saveDesign(_ model: DesignModel, _ command: String, path: String) async -> Bool {
        let engine = model.engine
        let busy = ProjectFiles.activity(for: model)
        busy?.begin(String(localized: "Saving \((path as NSString).lastPathComponent)"))
        let failure = await ActionTiming.measure("design.save") {
            await Task.detached(priority: .userInitiated) { () -> String? in
                do { try engine.execute(command, ["path": path]); return nil } catch { return error.localizedDescription }
            }.value
        }
        busy?.end()
        model.refresh()
        if let failure { model.flash(failure, error: true) }
        return failure == nil
    }

    static func newDesign(_ model: DesignModel) {
        // M-20: a new design gets its own tab unless this window is still blank.
        if DocTabs.wantsNewTab(model) { DocTabs.newTab(); return }
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

    /// Shows why a save failed and offers Try Again (the default), Save As or Cancel; tells
    /// `done` whether the file was written in the end.
    private static func report(_ ok: Bool, c: ProjectFiles.Context?, url: URL, design: DesignModel? = nil,
                               again: @escaping () -> Void, then done: ((Bool) -> Void)?) {
        guard !ok else {
            (c?.design ?? design)?.flash(String(localized: "Saved \(url.lastPathComponent)"))
            done?(true)
            return
        }
        let a = failureAlert(url: url, reason: c?.bom.message ?? design?.message ?? c?.design.message)
        switch a.runModal() {
        case .alertFirstButtonReturn: again()
        case .alertSecondButtonReturn:
            if let model = c?.design ?? design { saveAs(model, then: done) } else { done?(false) }
        default: done?(false)
        }
    }

    /// The failed-save alert: the reason, then Try Again (default, Return), Save As, Cancel (Esc).
    static func failureAlert(url: URL, reason: String?) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = String(localized: "“\(url.lastPathComponent)” could not be saved.")
        a.informativeText = (reason.map { $0 + "\n\n" } ?? "") + String(localized: "Your work is still open. Try again, or save a copy somewhere else.")
        a.addButton(withTitle: String(localized: "Try Again"))
        a.addButton(withTitle: String(localized: "Save As…"))
        a.addButton(withTitle: String(localized: "Cancel"))
        return a
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
        case .save: FileActions.save(model) { ok in if ok { proceed() } }
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

    /// Quit: asks for each edited window in turn; `done(false)` cancels the quit. A save runs
    /// off the main actor and the next window is asked once it is written.
    static func confirmQuit(_ done: @escaping (Bool) -> Void) {
        var queue = ProjectFiles.all.filter(ProjectFiles.isEdited)
        func next() {
            guard !queue.isEmpty else { return done(true) }
            let c = queue.removeFirst()
            switch ask(c, verb: String(localized: "Quit")) {
            case .save: FileActions.save(c.design) { ok in ok ? next() : done(false) }
            case .discard: next()
            case .cancel: done(false)
            }
        }
        next()
    }
}

/// The app delegate's quit check (`applicationShouldTerminate`).
final class ViaFormAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard ProjectFiles.all.contains(where: ProjectFiles.isEdited) else { return .terminateNow }
            // Saves run off the main actor: the answer comes once they are written.
            ProjectGuard.confirmQuit { sender.reply(toApplicationShouldTerminate: $0) }
            return .terminateLater
        }
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
            let p = CloseProxy(original: w.delegate) { [weak self, weak w] in
                guard let c = self?.project, ProjectFiles.isEdited(c) else { return true }
                switch ProjectGuard.ask(c, verb: String(localized: "Close")) {
                case .save:
                    // The save runs off the main actor; the window closes once it is written
                    // (then nothing is edited, so the close goes through).
                    FileActions.save(c.design) { ok in if ok { w?.performClose(nil) } }
                    return false
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
