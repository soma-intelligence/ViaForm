import SwiftUI

/// The eight workspaces in pipeline order, shared by the Mac and the iPad apps. Each one is a
/// stage of the product flow (`FlowModel`); the case names are the ones the Mac window used
/// before the enum moved here, so `--simulation` and the other launch flags keep their meaning.
enum Workspace: String, CaseIterable, Identifiable, Codable {
    case design, generate, assemble, electronics, simulation, train, render, make

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
        }
    }

    /// The stage id in the Rust core's pipeline.
    var stage: String { self == .simulation ? "simulate" : rawValue }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Command-1 to Command-8.
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(index + 1)")) }

    init?(stage: String) {
        guard let w = Self.allCases.first(where: { $0.stage == stage }) else { return nil }
        self = w
    }

    /// The tint of the stage's chip when it is the active one. Buttons keep the app's single
    /// accent; only the active chip of the pipeline bar wears this.
    var accent: Color {
        switch self {
        case .design: Color(red: 0.24, green: 0.55, blue: 1.0)
        case .generate: Color(red: 0.93, green: 0.36, blue: 0.62)
        case .assemble: Color(red: 0.55, green: 0.45, blue: 0.95)
        case .electronics: Color(red: 0.16, green: 0.72, blue: 0.66)
        case .simulation: Color(red: 0.98, green: 0.55, blue: 0.20)
        case .train: Color(red: 0.95, green: 0.70, blue: 0.15)
        case .render: Color(red: 0.40, green: 0.70, blue: 0.95)
        case .make: Color(red: 0.55, green: 0.62, blue: 0.70)
        }
    }

    /// The workspace a launch flag opens (`--design`, `--generate`, ... `--simulation`).
    static func fromLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) -> Workspace? {
        allCases.last { w in args.contains("--\(w.rawValue)") || args.contains("--stage=\(w.stage)") }
    }
}

/// The shared enum under a name a type with its own nested `Workspace` can point at.
typealias ViaFormWorkspace = Workspace
