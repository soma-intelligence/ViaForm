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
void vf_generate_cancel(const VfGenJob *job);
// Waits for the run: {"ok": outcome} or {"error": message} ("cancelled" when stopped).
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
// null). Small, so results open at once; take surfaces with vf_generate_mesh.
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
// Cancels a running study and frees the handle.
void vf_generate_free(VfGenJob *job);

#endif
