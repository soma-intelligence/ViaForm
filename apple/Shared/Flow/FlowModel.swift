import Foundation
import Observation
import SolidCraftFFI

/// The product pipeline, kept by the Rust core (`viaform_core::flow`, through `vf_flow_*`):
/// what each workspace consumes and produces and whether it is current. The workspaces report
/// what they build; the pipeline bar and the flow card read the status back.
@Observable
final class FlowModel {
    struct Stage: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let status: Status
        let artifacts: [String]
        let stale: Int
    }

    struct Input: Decodable, Equatable {
        let id: String
        let seen: Int
        let now: Int
        let current: Bool
    }

    struct Job: Decodable, Equatable {
        let label: String
        let progress: Double
    }

    struct Node: Decodable, Identifiable, Equatable {
        let id: String
        let stage: String
        let name: String
        let revision: Int
        let status: Status
        let summary: String
        let error: String?
        let job: Job?
        let consumes: [Input]
        let feeds: [String]
    }

    struct RunningJob: Decodable, Equatable {
        let artifact: String
        let stage: String
        let label: String
        let progress: Double
    }

    enum Status: String, Decodable {
        case current, empty, stale, running, failed
    }

    private struct State: Decodable {
        let stages: [Stage]
        let nodes: [Node]
        let jobs: [RunningJob]
    }

    private let handle: OpaquePointer?
    private(set) var stages: [Stage] = []
    private(set) var nodes: [Node] = []
    private(set) var jobs: [RunningJob] = []
    private(set) var error: String?

    init() {
        handle = vf_flow_new()
        refresh()
    }

    deinit { vf_flow_free(handle) }

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    func stage(_ id: String) -> Stage? { stages.first { $0.id == id } }
    func nodes(in stage: String) -> [Node] { nodes.filter { $0.stage == stage } }

    /// Records that `artifact` was just built from the current revisions of its inputs.
    func produce(_ artifact: String, summary: String? = nil) {
        send(["op": "produce", "artifact": artifact, "summary": summary])
    }

    func jobStart(_ artifact: String, label: String) {
        send(["op": "job_start", "artifact": artifact, "label": label])
    }

    func jobProgress(_ artifact: String, _ progress: Double) {
        send(["op": "job_progress", "artifact": artifact, "progress": progress])
    }

    /// A nil error builds the artifact; an error keeps its last build and marks it failed.
    func jobEnd(_ artifact: String, error: String? = nil, summary: String? = nil) {
        send(["op": "job_end", "artifact": artifact, "error": error, "summary": summary])
    }

    /// The stale or failed artifacts to rebuild, in order, so `artifact` is current.
    func planUpdate(_ artifact: String) -> [String] { order("plan_update", artifact) }

    /// Everything built from `artifact`, in build order.
    func downstream(_ artifact: String) -> [String] { order("downstream", artifact) }

    private func order(_ op: String, _ artifact: String) -> [String] {
        (call(["op": op, "artifact": artifact])?["order"] as? [String]) ?? []
    }

    private func send(_ command: [String: Any?]) {
        _ = call(command)
        refresh()
    }

    private func call(_ command: [String: Any?]) -> [String: Any]? {
        guard let handle,
              let data = try? JSONSerialization.data(withJSONObject: command.compactMapValues { $0 }),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let reply = Self.take(vf_flow_command(handle, text))
        let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
        error = object?["error"] as? String
        return object
    }

    private func refresh() {
        guard let handle else { error = "the pipeline did not start"; return }
        let reply = Self.take(vf_flow_state(handle))
        guard let s = try? JSONDecoder().decode(State.self, from: Data(reply.utf8)) else {
            error = "unreadable pipeline state"
            return
        }
        if s.stages != stages { stages = s.stages }
        if s.nodes != nodes { nodes = s.nodes }
        if s.jobs != jobs { jobs = s.jobs }
    }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "{}" }
        defer { sc_string_free(p) }
        return String(cString: p)
    }
}
