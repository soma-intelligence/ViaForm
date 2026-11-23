// Assemble (viaform_core::asm): the physical model of the product (assembly.json, viaform-asm
// v1): components, joints and drives, mass properties, interference, motion studies, MJCF and
// URDF interchange, saved poses, grasps and paths. One handle per open assembly; replies are
// JSON {"ok": ...} or {"error": message}, freed with sc_string_free.
//
// Units: mm in the design's world frame at the home pose, degrees (mm for prismatic joints),
// kg, N·m. Exports convert to SI. Poses come back per component as {component, pos_mm,
// quat [w, x, y, z], matrix (4x4, column-major, mm)}.
#ifndef VIAFORM_ASM_H
#define VIAFORM_ASM_H

typedef struct VfAsm VfAsm;
typedef struct ScSession ScSession;

VfAsm *vf_asm_new(void);
// From assembly.json text; null when it does not read or a newer ViaForm wrote it.
VfAsm *vf_asm_open(const char *assembly_json);
void vf_asm_free(VfAsm *asm_handle);

// Runs one op. sc may be null; when given, geometry and measured masses come from the open
// design, "mate_cad" reads its joints and "drive" moves its mated joints. Ops (params JSON):
//  get -> {assembly, state: {q, poses, dof, can_undo, can_redo}}; set {assembly}; validate
//  template {name: "arm"} -> {assembly, bom}  (six STS3215 joints, BOM lines)
//  add_component {component}, edit_component {id, ...fields}, remove_component {id}
//    -> {joints_removed}; set_ground {component | null}
//  joints -> {joints: [{...joint, drive: servo|tendon|none, value, unit}], dof}
//  add_joint {joint}, set_joint {id, ...fields}, remove_joint {id}
//  drive {joint, value} | {q: {joint: value}} -> {state, held: [{joint, requested, value, why}]}
//  fk {q?, pose?} -> {q, poses}
//  kin_model {tool?, tip_mm?} -> {model (viaform-kin JSON, SI), links, joints, tool}
//  mass_props {q?, pose?, geometry?, bom?} -> {components: [{component, mass_kg,
//    center_of_mass_mm, inertia_kg_mm2, sources}], total, bought_mass_kg, warnings}
//  interference {q?, pose?, cell_mm?, include_adjacent?} -> {pairs: [{a, b, volume_mm3,
//    region}], clear, components_checked}
//  motion_study {study: id} | {joint, from?, to?, steps?, pose?, duration_s?} -> {steps: [{step,
//    value, time_s, poses, end_effectors, joint_frame, collisions}], first_contacts, clear}
//  add_study {study}
//  export_mjcf | export_urdf {path?} -> {text, filename, warnings, check}
//  import_mjcf | import_urdf {text}; validate_mjcf | validate_urdf {text}
//  save_pose {id, q_deg?}, save_grasp {grasp}, save_path {path}   (asm.save_*)
//  mate_cad {inspect?}   (a joint.inspect reply; read from sc when given)
//  save {path} (writes assembly.json into the .viaform) -> {saved, produce}; open {path} -> {found}
//  commit -> {produce}: pass it to vf_flow_command to record "Assembly vN" in the pipeline
//  undo, redo
char *vf_asm_call(VfAsm *asm_handle, ScSession *sc, const char *op, const char *params_json);

#endif
