import Foundation
import SolidCraftFFI
import simd

/// The link between the electronics project and the 3D design. The work is done in the shared
/// Rust core (`viaform-core`), the same code the Electron app runs: the board becomes a
/// component of the design (board, copper, holes and simple part bodies), tagged with the PCB
/// revision it was built from. Updating rebuilds the bodies inside the same component, so its
/// placement and the joints that hold it in an assembly stay.
enum PCBLink {
    static let tag = "Linked to ViaForm PCB"

    /// The PCB revision the design's board component was built from, if there is one.
    static func linkedRevision(_ design: DesignModel, _ pcb: PCBModel) -> Int? {
        let r = vf_link_revision(design.engine.session, pcb.engine.session)
        return r < 0 ? nil : Int(r)
    }

    /// Builds or rebuilds the board component. Returns an error message, or nil.
    @discardableResult
    static func push(_ pcb: PCBModel, into design: DesignModel) -> String? {
        let err = reply(vf_link_push(design.engine.session, pcb.engine.session))
        design.refresh()
        if err == nil { pcb.linkedRevision = pcb.revision }
        return err
    }

    /// Seats the board's bottom face on a picked face of another part, its z along that face's
    /// normal, and holds it there with a rigid group.
    @discardableResult
    static func mount(_ pcb: PCBModel, in design: DesignModel, body target: String, at point: SIMD3<Double>, normal: SIMD3<Double>) -> String? {
        let p = [point.x, point.y, point.z], n = [normal.x, normal.y, normal.z]
        let err = reply(vf_link_mount(design.engine.session, pcb.engine.session, target, p, n))
        design.refresh()
        return err
    }

    /// The core's error message, or nil when it answered `ok`.
    private static func reply(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return "no reply from the engine" }
        defer { sc_string_free(p) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]
        return obj?["error"] as? String ?? (obj == nil ? "no reply from the engine" : nil)
    }
}
