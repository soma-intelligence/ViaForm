#ifndef VIAFORM_PHYS_H
#define VIAFORM_PHYS_H

// Physics (viaform-phys): articulated bodies on the kinematics model (Featherstone ABA, RNEA,
// CRBA), convex compliant contact with friction, servos, DC motors, tendons, the drone with its
// battery and motor heat, scenarios and the wrench history for loads from simulation. SI units,
// Z up.
//
// JSON calls: vf_phys_call(h, op, params) with op one of world_new, scenario_load, world_step,
// world_state, set_controls, episode_record, wrench_history, batch_new, batch_step,
// episode_start, job_poll, job_cancel, model_info. Replies are {"ok": result} or
// {"error": message, "code": code}, freed with sc_string_free.

typedef struct VfPhys VfPhys;

VfPhys *vf_phys_new(void);
void vf_phys_free(VfPhys *h);
char *vf_phys_call(VfPhys *h, const char *op, const char *params_json);

// Viewport path at 60 fps, no JSON. Poses are [x, y, z, qw, qx, qy, qz] per link (m, world
// frame, link 0 is the world), written for up to n links into out (n * 7 doubles); out may be
// null. Both return the number of links written; -1 when there is no world.
int vf_phys_state_poses(VfPhys *h, double *out, int n);
// Advances `steps` steps (a loaded scenario follows its drives) and writes the poses.
// Returns -2 when the step failed (the state diverged).
int vf_phys_step(VfPhys *h, int steps, double *out, int n);
// Sets n actuator controls in actuator order (rad, m, V or N m by actuator kind).
// Returns the number set, or -1 when there is no world.
int vf_phys_set_controls(VfPhys *h, const double *controls, int n);

#endif
