import Foundation

/// A toast's Undo bound to the one step it announced (P0-10), as the Generate toasts are: it
/// undoes that step only while it is still the newest one. After a newer edit it refuses with a
/// message rather than undo that edit instead.
@MainActor
struct DesignStep {
    let model: DesignModel
    let revision: Int
    let depth: Int

    /// The step the design engine just recorded.
    init(_ model: DesignModel) {
        self.model = model
        revision = model.snapshot.revision
        depth = model.snapshot.undo
    }

    /// Nothing changed the design since the step.
    var isNewest: Bool { model.snapshot.revision == revision && model.snapshot.undo == depth && depth > 0 }

    /// Undoes the step, or says why it cannot.
    func undo() {
        guard isNewest else {
            model.flash(String(localized: "Not undone: the design changed after this step. Use Edit, Undo to go back step by step."), error: true)
            return
        }
        model.undo()
    }
}
