// The product pipeline (viaform_core::flow): what each workspace consumes and produces, and
// whether it is current, with revisions ("Frame v12", "Board rev C"), the tree of each stage,
// the selection across stages, the commands of the eight stages and the jobs registry. One
// handle per project, JSON text both ways; every returned string is freed with sc_string_free.
#ifndef VIAFORM_FLOW_H
#define VIAFORM_FLOW_H

typedef struct VfFlow VfFlow;

VfFlow *vf_flow_new(void);
// The worked example: "Racer 3in" with Frame v12 promoted, a stale assembly and a study running.
VfFlow *vf_flow_new_sample(void);
void vf_flow_free(VfFlow *flow);

// {"product", "stages": [{id, name, status, artifacts, stale, reason, action}],
//  "nodes": [{id, stage, name, label, revision, revision_name, revisions, status, summary, from,
//  data, error, note, reason, action: {label, op, plan} | null, job, consumes: [{id, seen, now,
//  current, seen_name, now_name}], feeds}],
//  "jobs": [{id, artifact, stage, verb, label, progress, determinate, done, total, eta, elapsed,
//  caption, state: running | paused, pausable, control}],
//  "selection": {stage, ids, names, anchor, linked: [{stage, count, ids, names}]}}
// status: current, empty, stale, running, failed
char *vf_flow_state(const VfFlow *flow);

// Changes, each {"op": ..., ...}; answers {"ok": true, ...} or {"error": ...}:
//  produce {artifact, summary?, fingerprint?, amend_within?, data?, source?}
//    -> {revision, result: new | amended | unchanged | restored}
//  promote {artifact, from, summary?, data?}   ("Use as Frame")
//  activate {artifact, revision}               (go back to an older revision)
//  job_start {artifact, verb?, label?, total?, expected?, pausable?} -> {job}
//  job_progress | job_pause | job_resume | job_cancel | job_end, by {job} or {artifact}
//    (progress?, done?, total?, label?; job_end: error?, summary?, data?)
//  tree_report {stage, items: [{id, name, kind, parent?, artifact?, links?, detail?}]}
//  tree_set {id, visible?, locked?}
//  select {stage, ids, anchor?: [x, y, z]}
//  set_product {name}, set_graph {graph}, import {doc}, reset
//  save {path}  (writes flow.json into an existing .viaform), open {path} -> {found}
// The read ops of vf_flow_query are accepted here too.
char *vf_flow_command(VfFlow *flow, const char *command_json);

// Reads, each {"op": ..., ...}:
//  revisions {artifact} -> {list: {artifact, active, revisions: [{number, name, summary, source,
//    from, at, data, active, used_by, inputs}]}}
//  diff {artifact, from?, to?} -> {diff: {from, to, summary, inputs, figures, same_content}}
//  plan_update | downstream {artifact} -> {order}
//  outputs -> {outputs: [{id, stage, name, label, revision, revision_name, status, reason, action}]}
//  tree {stage} -> {tree: {stage, rows: [{id, name, kind, detail, depth, parent, children,
//    visible, locked, shown, held, selected, status?, links}]}}
//  selection, commands {stage?}, search {query, stage?, limit?} -> {results: [{score, command}]},
//  export -> {doc}, state -> {state}
char *vf_flow_query(const VfFlow *flow, const char *query_json);

// Polls the Rust workers attached to jobs: {"ended": [job ids]}.
char *vf_flow_tick(VfFlow *flow);

// The command catalog of the eight stages, without a project.
char *vf_flow_commands(void);

#endif
