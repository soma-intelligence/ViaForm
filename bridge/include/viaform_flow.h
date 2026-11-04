// The product pipeline (viaform_core::flow): what each workspace consumes and produces, and
// whether it is current. One handle per project, JSON text both ways; every returned string is
// freed with sc_string_free.
#ifndef VIAFORM_FLOW_H
#define VIAFORM_FLOW_H

typedef struct VfFlow VfFlow;

VfFlow *vf_flow_new(void);
void vf_flow_free(VfFlow *flow);
// {"stages": [{id, name, status, artifacts, stale}], "nodes": [{id, stage, name, revision,
//  status, summary, error, job, consumes: [{id, seen, now, current}], feeds}], "jobs": [...]}
// status: current, empty, stale, running, failed
char *vf_flow_state(const VfFlow *flow);
// {"op": "produce" | "job_start" | "job_progress" | "job_end" | "plan_update" | "downstream"
//  | "reset", "artifact": "generate.frame", "summary"?, "label"?, "progress"?, "error"?}
char *vf_flow_command(VfFlow *flow, const char *command_json);

#endif
