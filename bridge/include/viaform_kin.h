#ifndef VIAFORM_KIN_H
#define VIAFORM_KIN_H

// Kinematics (viaform-kin): robot model, forward kinematics, Jacobians, inverse kinematics
// (numerical for every model, analytic for 6-axis arms with a spherical wrist), hand grasps
// with couplings and tendons, Cartesian paths. SI units, Z up.
//
// JSON calls: vf_kin_call(k, op, params) with op one of model.load, model.info, model.json, fk,
// jacobian, ik, ik_hand, path.cartesian, ik_drag_begin, ik_drag_move, ik_drag_end. Replies are
// {"ok": result} or {"error": message, "code": code}, freed with sc_string_free.
// Poses in JSON are {"xyz": [x, y, z], "quat_wxyz": [w, x, y, z]} (or "rpy" in radians).

typedef struct VfKin VfKin;

VfKin *vf_kin_new(void);
void vf_kin_free(VfKin *k);
char *vf_kin_call(VfKin *k, const char *op, const char *params_json);

// Drag end effector at 60 fps, no JSON: begin with vf_kin_call(k, "ik_drag_begin",
// {"frame", "q", "keep_orientation", "locked"}), then for each pointer move pass the target
// pose [x, y, z, qw, qx, qy, qz] (m). Writes n joint values into q_out and n_links link
// matrices (16 floats each, 4x4 column-major, world frame) into poses_out; either may be null.
// Returns 0 reached, 1 stretching toward an unreachable target, -1 error (no drag, several
// frames, bad pose). End with "ik_drag_end" ({"cancel": true} restores the start pose, Esc).
int vf_kin_drag_move(VfKin *k, const double pose[7], double *q_out, int n, float *poses_out, int n_links);
// Error of the last drag move: out[0] distance left (m), out[1] orientation error (rad).
// Returns 0, or -1 when no move was made.
int vf_kin_drag_error(const VfKin *k, double out[2]);

#endif
