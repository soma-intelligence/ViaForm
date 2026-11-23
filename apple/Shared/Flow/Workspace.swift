import SwiftUI

/// The nine workspaces in pipeline order, shared by the Mac and the iPad apps. Each one is a
/// stage of the product flow (`FlowModel`); the case names are the ones the Mac window used
/// before the enum moved here, so `--simulation` and the other launch flags keep their meaning.
enum Workspace: String, CaseIterable, Identifiable, Codable {
    case design, generate, assemble, electronics, simulation, train, render, make, robot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simulation: "Simulate"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .design: "cube"
        case .generate: "wand.and.rays"
        case .assemble: "gearshape.2"
        case .electronics: "cpu"
        case .simulation: "wind"
        case .train: "brain"
        case .render: "camera.aperture"
        case .make: "shippingbox"
        case .robot: "figure.arms.open"
        }
    }

    /// The label of the pipeline bar's short fold.
    var shortTitle: String {
        switch self {
        case .design: "Design"
        case .generate: "Gen"
        case .assemble: "Asm"
        case .electronics: "PCB"
        case .simulation: "Sim"
        case .train: "Train"
        case .render: "Rndr"
        case .make: "Make"
        case .robot: "Robot"
        }
    }

    /// The stage id in the Rust core's pipeline.
    var stage: String { self == .simulation ? "simulate" : rawValue }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Command-1 to Command-9.
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(index + 1)")) }

    init?(stage: String) {
        guard let w = Self.allCases.first(where: { $0.stage == stage }) else { return nil }
        self = w
    }

    /// The tint of the stage's chip when it is the active one: the stage tone of the theme.
    /// Buttons keep the app's single accent; only the active chip of the pipeline bar wears this.
    func accent(_ theme: ViaFormTheme) -> Color {
        VFStage(stageID: stage).map(theme.stageFill) ?? theme.accent
    }

    /// The workspace a launch flag opens (`--design`, `--generate`, ... `--simulation`).
    static func fromLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) -> Workspace? {
        allCases.last { w in args.contains("--\(w.rawValue)") || args.contains("--stage=\(w.stage)") }
    }
}

/// The shared enum under a name a type with its own nested `Workspace` can point at.
typealias ViaFormWorkspace = Workspace
