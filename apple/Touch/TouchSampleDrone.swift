#if os(iOS)
import SwiftUI

/// The 3 inch racer for `--drone` on the iPad: the same steps as the Mac's `DeskSamples.drone`
/// (centre plate sized to the sample board, four arms, four motor bells, the board sent to 3D
/// and mounted on the plate), so both front ends open the same product.
enum TouchSampleDrone {
    @MainActor
    static func build(into model: DesignModel, pcb: PCBModel) {
        model.newDesign()
        guard let b = pcb.project?.board else { return }
        let plate = (x: b.width + 12, y: b.height + 8, z: 3.0)
        let arm = 64.0
        var steps: [(String, [String: Any])] = [
            ("component.activate", ["component": "root"]),
            ("component.create", ["name": "Frame"]),
            ("solid.box", ["length": plate.x, "width": plate.y, "height": plate.z, "corner": [-plate.x / 2, -plate.y / 2, 0], "body_name": "Frame"]),
            ("solid.box", ["length": arm * 2 + plate.x, "width": 8, "height": plate.z, "corner": [-arm - plate.x / 2, -4, 0], "body_name": "Arms X"]),
            ("solid.box", ["length": 8, "width": arm * 2 + plate.y, "height": plate.z, "corner": [-4, -arm - plate.y / 2, 0], "body_name": "Arms Y"]),
        ]
        for (i, c) in [(arm + plate.x / 2, 0.0), (-arm - plate.x / 2, 0.0), (0.0, arm + plate.y / 2), (0.0, -arm - plate.y / 2)].enumerated() {
            steps.append(("component.activate", ["component": "root"]))
            steps.append(("component.create", ["name": "Motor \(i + 1)"]))
            steps.append(("solid.cylinder", ["base": [c.0, c.1, plate.z], "axis": [0, 0, 1], "radius": 7, "height": 9, "operation": "new"]))
        }
        steps.append(("component.activate", ["component": "root"]))
        for (id, p) in steps { model.run(id, p, quiet: true) }
        pcb.sendTo3D(model)
        PCBLink.mount(pcb, in: model, body: "Frame", at: [0, 0, plate.z], normal: [0, 0, 1])
        pcb.message = nil
        model.message = nil
        model.setView(.iso)
        model.zoomToFit()
    }
}

/// Apple Pencil double tap (or squeeze): from a tool back to Select, and from Select back to the
/// last tool, so the hand never leaves the canvas to switch. iPadOS 17.5 and later.
private struct PencilToolToggle: ViewModifier {
    let model: DesignModel
    @State private var last: Tool = .pressPull

    func body(content: Content) -> some View {
        if #available(iOS 17.5, *) {
            content.onPencilDoubleTap { _ in toggle() }
        } else {
            content
        }
    }

    private func toggle() {
        if model.tool != .select {
            last = model.tool
            model.hasPreview ? model.cancelTool() : (model.tool = .select)
        } else {
            model.tool = last
        }
    }
}

extension View {
    func pencilDoubleTapTogglesTool(_ model: DesignModel) -> some View { modifier(PencilToolToggle(model: model)) }
}
#endif
