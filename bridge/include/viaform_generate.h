// Generative studies as jobs (viaform-core::generative::Job): start a 3D study on its own thread,
// poll its progress, cancel it, take its outcome, build a candidate without running it again.
// Every returned string is freed with sc_string_free.
#ifndef VIAFORM_GENERATE_H
#define VIAFORM_GENERATE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct VfGenJob VfGenJob;
typedef struct ScSession ScSession;

// Null when the study does not read; *error (if error is not null) then gets {"error": ...}.
VfGenJob *vf_generate_start(const char *spec_json, char **error);
// {running, cancelled, paused, variant, variants, iteration, iterations, objective, stage,
//  fraction (0..1 over every variant), seconds (wall, since start), eta (seconds still to solve:
//  mean of the last five iterations times those left, pauses excluded; null before two
//  iterations), per_iteration (s), paused_seconds, preview (latest preview version)}.
// Poll it a few times a second; it never waits.
char *vf_generate_progress(const VfGenJob *job);
// Asks the run to stop at its next iteration; it then keeps its best design so far. Safe to
// call again, before or after the run ends.
void vf_generate_cancel(const VfGenJob *job);
// Waits for the run: {"ok": outcome} or {"error": message}. A stopped run answers its outcome
// with stopped true: the candidates finished before the stop plus the stopped one's best iterate
// so far (converged false), analysed and surfaced like the others. "cancelled" only when it was
// stopped before any usable shape.
char *vf_generate_outcome(const VfGenJob *job);
// Builds candidate (-1: the best) into the design, one undo step: {"ok": {candidate, body, commands}}.
char *vf_generate_build(ScSession *s, const VfGenJob *job, int64_t candidate);
// Holds the run after its current iteration (paused true) or lets it go on (false).
void vf_generate_pause(const VfGenJob *job, bool paused);
// Live convergence: the iterations from `from` on (0: all) as a JSON array of
// {variant, iteration, iterations, objective, compliance (N mm), volume (fraction),
//  max_stress (peak relaxed von Mises, MPa), seconds}. Never waits; poll with from = count seen.
char *vf_generate_history(const VfGenJob *job, uint64_t from);
// Waits for the run: {"ok": {candidates, best, seconds, warnings}}, each candidate's figures
// (no densities, no surface; `triangles` counts it) plus cost (rough $ index) and f1 (Hz or
// null), converged (false: a stopped run's kept iterate), stopped_at (iterations run at the stop,
// else null) and kept_iteration (the iteration kept, else null); a stopped run adds a warning
// starting "stopped at iteration". Small, so results open at once; take surfaces with
// vf_generate_mesh.
char *vf_generate_summary(const VfGenJob *job);

// A triangle mesh as flat arrays, world mm: vertex_count xyz triples, index_count indices
// (three per triangle), stress one MPa value per vertex or NULL. For previews, version orders
// them and variant/iteration say which run state they show. Free with vf_generate_mesh_free.
typedef struct VfGenMesh {
    const float *positions;
    uint64_t vertex_count;
    const uint32_t *indices;
    uint64_t index_count;
    const float *stress;
    uint64_t version;
    uint64_t variant;
    uint64_t iteration;
} VfGenMesh;
// The live shape: a coarse iso surface (density 0.5, averaged to at most 48 000 cells) of the
// latest iteration, when newer than `since` (0 the first time, then the last version), else
// NULL. Surfacing runs on the calling thread (call it off the main thread); never waits.
VfGenMesh *vf_generate_preview(const VfGenJob *job, uint64_t since);
// Waits for the run, then candidate's (-1: the best) final surface; NULL on error.
VfGenMesh *vf_generate_mesh(const VfGenJob *job, int64_t candidate);
void vf_generate_mesh_free(VfGenMesh *mesh);
// A variant of a study: base study JSON with {label, volume_fraction, material, process
// ("fdm" | "sls" | "cnc3" | "as_is"), build [x,y,z], any other study field} laid over it, one
// candidate, at least one mode. {"ok": study} or {"error"}. Run each as its own job.
char *vf_generate_variant(const char *base_json, const char *variant_json);
// Loads from simulation (G3, op loads_from_record): a phys wrench record (wrench_history's
// answer, bare or {"ok": [...]}, or a recorder) reduced to governing load cases. Request:
// {record, body, interfaces: [{source, region, center?}], placement?: {origin (mm), rotation
// [w,x,y,z] link to study}, max_cases? (8), similarity? (0.95 cosine), min_share? (0.05),
// dynamic_factor? (1), safety_factor? (1), gravity? (link frame m/s^2: adds the body load),
// at? (s: one case at that time), name?}. Answers {"ok": {cases: [{case (a study load case,
// mm/N), t, sample, governs, force, moment, scale}], samples, peak_force, peak_moment,
// dropped}} or {"error"}.
char *vf_generate_loads_from_record(const char *request_json);
// Mesh checks (VIAFORM-SPEC 7.10.3), op check_mesh: a surface as flat arrays (as VfGenMesh) and
// a request {process ("free" | "additive" | "fdm" | "sls" | "resin" | "milling" | "extrusion"),
// build [x,y,z], overhang (deg from the plate, 45), min_wall (mm, default the process minimum),
// max_bodies (1), plate_tolerance (mm, 0.5), samples (20000)} or NULL for the defaults.
// Answers {"ok": {checks: [{id (watertight | manifold | bodies | min_wall | overhangs | voids |
// triangles), name, status (pass | warning | fail | skipped), value, limit, unit, detail,
// spot: {min, max} or null}], triangles, vertices, area_mm2, volume_mm3, open_edges,
// nonmanifold_edges, bodies, voids, min_wall_mm, thin_share, wall_samples, overhang_mm2,
// overhang_share, passed, warnings, failures, seconds}} or {"error"}. Call it off the main thread.
char *vf_generate_check_mesh(const float *positions, uint64_t vertex_count, const uint32_t *indices,
                             uint64_t index_count, const char *request_json);
// Writes a surface to a file, op export_mesh: request {path, format ("stl" | "3mf" | "obj";
// default the path's extension), name?}. Written beside the final name, then renamed into
// place. {"ok": {path, format, bytes, triangles}} or {"error": why, in words}.
char *vf_generate_export_mesh(const float *positions, uint64_t vertex_count, const uint32_t *indices,
                              uint64_t index_count, const char *request_json);
// Cancels a running study and frees the handle.
void vf_generate_free(VfGenJob *job);

#endif
