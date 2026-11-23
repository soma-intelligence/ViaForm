import Foundation
import ViaFormFFI

/// Where `FlowModel` gets the pipeline from: the Rust core (`RustFlow`) in the app, a canned
/// project (`MockFlow`) in previews and model checks. JSON text both ways, like `vf_flow_*`.
protocol FlowService: AnyObject {
    /// `vf_flow_state`.
    func state() -> String
    /// `vf_flow_command`: changes, and the read ops too.
    func command(_ json: String) -> String
    /// `vf_flow_query`: reads only.
    func query(_ json: String) -> String
    /// `vf_flow_tick`: polls the Rust workers attached to jobs.
    func tick() -> String
}

/// The pipeline kept by the Rust core.
final class RustFlow: FlowService {
    private let handle: OpaquePointer?

    init(sample: Bool = false) {
        handle = sample ? vf_flow_new_sample() : vf_flow_new()
    }

    deinit { vf_flow_free(handle) }

    func state() -> String {
        guard let handle else { return #"{"error":"the pipeline did not start"}"# }
        return Self.take(vf_flow_state(handle))
    }

    func command(_ json: String) -> String {
        guard let handle else { return #"{"error":"the pipeline did not start"}"# }
        return Self.take(vf_flow_command(handle, json))
    }

    func query(_ json: String) -> String {
        guard let handle else { return #"{"error":"the pipeline did not start"}"# }
        return Self.take(vf_flow_query(handle, json))
    }

    func tick() -> String {
        guard let handle else { return "{}" }
        return Self.take(vf_flow_tick(handle))
    }

    /// The command catalog of the eight stages, no project needed.
    static func catalog() -> String { take(vf_flow_commands()) }

    static func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "{}" }
        defer { sc_string_free(p) }
        return String(cString: p)
    }
}

/// A canned project for previews and model checks, with no engine behind it: "Racer 3in" with
/// Frame v12 just promoted, the assembly stale on it, Board rev C, Policy v5 and a frame study
/// running. It answers the reads from fixed data and records every change it is sent.
final class MockFlow: FlowService {
    private(set) var sent: [[String: Any]] = []
    private var selection: [String: Any] = ["stage": "design", "ids": ["body:Frame"], "names": ["Frame"], "anchor": [0, 0, 12],
                                            "linked": [["stage": "assemble", "count": 1, "ids": ["occ:Frame"], "names": ["Frame:1"]]]]
    private var paused = false

    private static let stages: [(String, String)] = [
        ("design", "Design"), ("generate", "Generate"), ("assemble", "Assemble"), ("electronics", "Electronics"),
        ("simulate", "Simulate"), ("train", "Train"), ("render", "Render"), ("make", "Make"),
    ]

    /// id, stage, name, label, revision, revision name, status, summary, reason, inputs
    private static let nodes: [(String, String, String, String, Int, String?, String, String, String, [String])] = [
        ("design.model", "design", "Design model", "Model", 12, "Model v12", "current", "Arms, motor pods, battery bay", "", []),
        ("generate.frame", "generate", "Generated frame", "Frame", 12, "Frame v12", "running", "Outcome 13, 153 g", "Generating 74 of 120 · 3 min left", ["design.model"]),
        ("electronics.board", "electronics", "Flight controller board", "Board", 3, "Board rev C", "current", "36 x 36 mm, 112 nets, DRC passed", "", []),
        ("assemble.assembly", "assemble", "Assembly", "Assembly", 1, "Assembly v1", "stale", "Frame v11, Board rev C, 4 motors", "Frame v12 replaced v11", ["design.model", "generate.frame", "electronics.board"]),
        ("simulate.flight", "simulate", "Flight log", "Flight", 4, "Flight v4", "stale", "Gate course, wind 4 m/s", "Assembly v1 is stale: Frame v12 replaced v11", ["assemble.assembly"]),
        ("train.policy", "train", "Flight policy", "Policy", 5, "Policy v5", "stale", "PID + residual, held-out cost 0.41", "Flight v4 is stale", ["simulate.flight"]),
        ("render.shots", "render", "Renders", "Renders", 1, "Renders v1", "stale", "6 shots", "Assembly v1 is stale", ["assemble.assembly"]),
        ("make.bundle", "make", "Manufacturing bundle", "Bundle", 0, nil, "empty", "", "Not built yet", ["generate.frame", "electronics.board", "assemble.assembly", "train.policy"]),
    ]

    private func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private var job: [String: Any] {
        ["id": 1, "artifact": "generate.frame", "stage": "generate", "verb": "Generating", "label": "Frame study, 120 outcomes",
         "progress": 74.0 / 120, "determinate": true, "done": 74, "total": 120, "eta": 180.0, "elapsed": 290.0,
         "caption": paused ? "Generating 74 of 120 · paused" : "Generating 74 of 120 · 3 min left",
         "state": paused ? "paused" : "running", "pausable": true]
    }

    private func action(_ status: String) -> Any {
        status == "stale" ? ["label": "Re-run on Frame v12", "op": "update", "plan": ["assemble.assembly", "simulate.flight"]] as [String: Any] : NSNull()
    }

    func state() -> String {
        let nodes: [[String: Any]] = Self.nodes.map { n in
            [
                "id": n.0, "stage": n.1, "name": n.2, "label": n.3, "revision": n.4, "revision_name": n.5 ?? NSNull(), "revisions": n.4,
                "status": n.6, "summary": n.7, "reason": n.8, "action": action(n.6), "job": n.0 == "generate.frame" ? job : NSNull(),
                "consumes": n.9.map { i in ["id": i, "seen": 1, "now": 1, "current": n.6 != "stale", "seen_name": "\(i) v1", "now_name": "\(i) v1"] },
                "feeds": Self.nodes.filter { $0.9.contains(n.0) }.map(\.0),
            ]
        }
        let stages: [[String: Any]] = Self.stages.map { s in
            let own = Self.nodes.filter { $0.1 == s.0 }
            let status = own.first?.6 ?? "empty"
            return ["id": s.0, "name": s.1, "status": status, "artifacts": own.map(\.0), "stale": own.filter { $0.6 == "stale" }.count,
                    "reason": own.first?.8 ?? "", "action": action(status)]
        }
        return json(["product": "Racer 3in", "stages": stages, "nodes": nodes, "jobs": [job], "selection": selection])
    }

    func command(_ text: String) -> String {
        guard let cmd = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return #"{"error":"not JSON"}"# }
        let op = cmd["op"] as? String ?? ""
        if ["revisions", "diff", "tree", "selection", "outputs", "commands", "search", "plan_update", "downstream", "export", "state"].contains(op) {
            return query(text)
        }
        sent.append(cmd)
        switch op {
        case "job_pause": paused = true
        case "job_resume": paused = false
        case "select":
            selection = ["stage": cmd["stage"] ?? "", "ids": cmd["ids"] ?? [], "names": cmd["ids"] ?? [], "linked": []]
        default: break
        }
        return #"{"ok":true,"revision":1,"job":1}"#
    }

    func query(_ text: String) -> String {
        guard let cmd = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return #"{"error":"not JSON"}"# }
        switch cmd["op"] as? String ?? "" {
        case "tree":
            let rows: [[String: Any]] = [
                ["id": "design.model", "name": "Design model", "kind": "artifact", "detail": "Model v12", "depth": 0, "children": 2, "visible": true, "locked": false, "shown": true, "held": false, "selected": false, "status": "current", "links": []],
                ["id": "body:Frame", "name": "Frame", "kind": "body", "detail": "153 g", "depth": 1, "children": 0, "visible": true, "locked": false, "shown": true, "held": false, "selected": true, "links": ["part:Frame"]],
                ["id": "body:Pods", "name": "Motor pods", "kind": "body", "depth": 1, "children": 0, "visible": false, "locked": true, "shown": false, "held": true, "selected": false, "links": []],
            ]
            return json(["ok": true, "tree": ["stage": cmd["stage"] ?? "design", "rows": rows]])
        case "outputs":
            let outputs: [[String: Any]] = Self.nodes.map { n in
                ["id": n.0, "stage": n.1, "name": n.2, "label": n.3, "revision": n.4, "revision_name": n.5 ?? NSNull(), "status": n.6, "reason": n.8, "action": action(n.6)]
            }
            return json(["ok": true, "outputs": outputs])
        case "revisions":
            let list: [[String: Any]] = [
                ["number": 11, "name": "Frame v11", "summary": "Outcome 9, 161 g", "source": "build", "at": 0, "active": false, "used_by": ["assemble.assembly"], "inputs": []],
                ["number": 12, "name": "Frame v12", "summary": "Outcome 13, 153 g", "source": "promote", "from": "Outcome 13", "at": 0, "active": true, "used_by": [], "inputs": []],
            ]
            return json(["ok": true, "list": ["artifact": cmd["artifact"] ?? "", "active": 12, "revisions": list]])
        case "diff":
            return json(["ok": true, "diff": ["artifact": cmd["artifact"] ?? "", "from": "Frame v11", "to": "Frame v12",
                                              "summary": ["from": "Outcome 9, 161 g", "to": "Outcome 13, 153 g", "changed": true],
                                              "inputs": [], "figures": [["key": "mass_g", "from": 161, "to": 153]], "same_content": false]])
        case "search", "commands":
            let commands: [[String: Any]] = [
                ["id": "generate.use_as_frame", "label": "Use as Frame", "stage": "generate", "group": "OUTCOMES", "icon": "promote", "source": "app", "detail": ""],
                ["id": "solid.extrude", "label": "Extrude", "stage": "design", "group": "SOLID CREATE", "icon": "extrude", "key": "E", "source": "design", "detail": ""],
                ["id": "pcb.track.route", "label": "Route track", "stage": "electronics", "group": "TRACK", "icon": "track", "source": "pcb", "detail": ""],
            ]
            return cmd["op"] as? String == "search"
                ? json(["ok": true, "results": commands.map { ["score": 100, "command": $0] }])
                : json(["ok": true, "commands": commands])
        case "selection": return json(["ok": true, "selection": selection])
        case "plan_update", "downstream": return json(["ok": true, "order": ["assemble.assembly", "simulate.flight"]])
        default: return json(["ok": true])
        }
    }

    func tick() -> String { #"{"ended":[]}"# }
}
