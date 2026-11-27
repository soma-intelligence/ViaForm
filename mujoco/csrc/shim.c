// Thin C accessors over mjModel and mjData for viaform-mujoco, so the Rust side never mirrors
// MuJoCo's struct layouts (which change between releases). Compiled against the pinned
// release's headers by build.rs. Our code, MIT OR Apache-2.0.

#include <string.h>
#include <mujoco/mujoco.h>

// Model from an MJCF string (mjSpec path, no file system). NULL on error, message in `err`.
mjModel* vfmj_load_xml(const char* xml, char* err, int err_sz) {
  mjSpec* spec = mj_parseXMLString(xml, NULL, err, err_sz);
  if (!spec) return NULL;
  mjModel* m = mj_compile(spec, NULL);
  if (!m) {
    const char* e = mjs_getError(spec);
    if (e && err && err_sz > 0) {
      strncpy(err, e, err_sz - 1);
      err[err_sz - 1] = 0;
    }
  }
  mj_deleteSpec(spec);
  return m;
}

const char* vfmj_version(void) { return mj_versionString(); }

mjModel* vfmj_copy_model(const mjModel* m) { return mj_copyModel(NULL, m); }
void vfmj_delete_model(mjModel* m) { mj_deleteModel(m); }
mjData* vfmj_make_data(const mjModel* m) { return mj_makeData(m); }
mjData* vfmj_copy_data(const mjModel* m, const mjData* d) { return mj_copyData(NULL, m, d); }
void vfmj_delete_data(mjData* d) { mj_deleteData(d); }

void vfmj_step(const mjModel* m, mjData* d) { mj_step(m, d); }
void vfmj_forward(const mjModel* m, mjData* d) { mj_forward(m, d); }
void vfmj_kinematics(const mjModel* m, mjData* d) { mj_kinematics(m, d); mj_comPos(m, d); }
void vfmj_rne_post(const mjModel* m, mjData* d) { mj_rnePostConstraint(m, d); }

// Sizes: nq, nv, nu, nbody, njnt, ngeom, ntendon, nout.
void vfmj_sizes(const mjModel* m, long long out[8]) {
  out[0] = m->nq; out[1] = m->nv; out[2] = m->nu; out[3] = m->nbody;
  out[4] = m->njnt; out[5] = m->ngeom; out[6] = m->ntendon; out[7] = m->nout;
}

// Name lookups: kind 0 body, 1 joint, 2 actuator, 3 geom, 4 tendon.
int vfmj_id(const mjModel* m, int kind, const char* name) {
  static const int types[5] = {mjOBJ_BODY, mjOBJ_JOINT, mjOBJ_ACTUATOR, mjOBJ_GEOM, mjOBJ_TENDON};
  if (kind < 0 || kind > 4) return -1;
  return mj_name2id(m, types[kind], name);
}

int vfmj_jnt_qposadr(const mjModel* m, int j) { return m->jnt_qposadr[j]; }
int vfmj_jnt_dofadr(const mjModel* m, int j) { return m->jnt_dofadr[j]; }
int vfmj_geom_body(const mjModel* m, int g) { return m->geom_bodyid[g]; }
int vfmj_body_rootid(const mjModel* m, int b) { return m->body_rootid[b]; }
double vfmj_timestep(const mjModel* m) { return m->opt.timestep; }
mjtNum* vfmj_actuator_forcerange(mjModel* m) { return m->actuator_forcerange; }

// mjData arrays.
double vfmj_time(const mjData* d) { return d->time; }
void vfmj_set_time(mjData* d, double t) { d->time = t; }
mjtNum* vfmj_qpos(mjData* d) { return d->qpos; }
mjtNum* vfmj_qvel(mjData* d) { return d->qvel; }
mjtNum* vfmj_qacc(mjData* d) { return d->qacc; }
mjtNum* vfmj_ctrl(mjData* d) { return d->ctrl; }
mjtNum* vfmj_act_force(mjData* d) { return d->actuator_force; }
mjtNum* vfmj_act_length(mjData* d) { return d->actuator_length; }
mjtNum* vfmj_act_velocity(mjData* d) { return d->actuator_velocity; }
mjtNum* vfmj_xpos(mjData* d) { return d->xpos; }
mjtNum* vfmj_xquat(mjData* d) { return d->xquat; }
mjtNum* vfmj_xmat(mjData* d) { return d->xmat; }
mjtNum* vfmj_xipos(mjData* d) { return d->xipos; }
mjtNum* vfmj_cvel(mjData* d) { return d->cvel; }
mjtNum* vfmj_cacc(mjData* d) { return d->cacc; }
mjtNum* vfmj_cfrc_int(mjData* d) { return d->cfrc_int; }
mjtNum* vfmj_subtree_com(mjData* d) { return d->subtree_com; }
mjtNum* vfmj_xfrc_applied(mjData* d) { return d->xfrc_applied; }
int vfmj_niter(const mjData* d) { return d->solver_niter[0]; }
int vfmj_nefc(const mjData* d) { return d->nefc; }
// Count of the bad-number warnings (qpos, qvel, qacc): the state diverged.
int vfmj_bad_state(const mjData* d) {
  return d->warning[mjWARN_BADQPOS].number + d->warning[mjWARN_BADQVEL].number + d->warning[mjWARN_BADQACC].number;
}

// Contacts: count, then per contact [dist, pos(3), normal(3), force on geom 2 in world(3)] and
// the two body ids. Only contacts that entered the solver are listed.
int vfmj_ncon(const mjData* d) { return d->ncon; }
int vfmj_contact(const mjModel* m, const mjData* d, int i, double out[10], int bodies[2]) {
  const mjContact* c = d->contact + i;
  if (c->exclude != 0 || c->efc_address < 0 || c->geom[0] < 0 || c->geom[1] < 0) return 0;
  mjtNum f[6];
  mj_contactForce(m, d, i, f);
  out[0] = c->dist;
  for (int k = 0; k < 3; k++) {
    out[1 + k] = c->pos[k];
    out[4 + k] = c->frame[k];
    // frame rows: normal, tangent 1, tangent 2; f is in that frame, the force geom 1 puts on geom 2.
    out[7 + k] = c->frame[k] * f[0] + c->frame[3 + k] * f[1] + c->frame[6 + k] * f[2];
  }
  bodies[0] = m->geom_bodyid[c->geom[0]];
  bodies[1] = m->geom_bodyid[c->geom[1]];
  return 1;
}
