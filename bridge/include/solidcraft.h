// C ABI of the SolidCraft (CAD) and PCBCraft (PCB) engines for the native Swift front end (bridge/src/lib.rs).
// Every char* this library returns is freed with sc_string_free.
#ifndef SOLIDCRAFT_H
#define SOLIDCRAFT_H

#include <stdbool.h>
#include <stdint.h>

typedef struct ScSession ScSession;
typedef struct ScScene ScScene;

typedef struct {
    const float *positions;
    const float *normals;
    uint32_t vertex_count;
    const uint32_t *indices;
    uint32_t index_count;
    const uint32_t *tri_face;
    const float *edge_points;
    const uint32_t *edge_offsets;
    uint32_t edge_count;
    float color[4];
} ScMeshView;

typedef struct {
    const float *points;
    uint32_t point_count;
    float color[4];
    float width;
    bool on_top;
} ScLineView;

ScSession *sc_session_new(void);
void sc_session_free(ScSession *s);

char *sc_execute(ScSession *s, const char *id, const char *params_json);
char *sc_run_script(ScSession *s, const char *script_json);
char *sc_commands(void);
char *sc_home_camera(const ScSession *s);
char *sc_bounds(const ScSession *s);
char *sc_sketch_plane(const ScSession *s);
void sc_string_free(char *p);

ScScene *sc_scene_build(ScSession *s, const char *camera_json);
void sc_scene_free(ScScene *sc);
float sc_scene_radius(const ScScene *sc);
void sc_scene_background(const ScScene *sc, float *out8);
uint32_t sc_scene_mesh_count(const ScScene *sc);
bool sc_scene_mesh(const ScScene *sc, uint32_t i, ScMeshView *out);
const char *sc_scene_body_name(const ScScene *sc, uint32_t i);
uint32_t sc_scene_line_count(const ScScene *sc, bool grid);
bool sc_scene_line(const ScScene *sc, bool grid, uint32_t i, ScLineView *out);

// PCB (PCBCraft engine)
typedef struct PcbSession PcbSession;
PcbSession *pcb_session_new(bool sample);
void pcb_session_free(PcbSession *s);
char *pcb_execute(PcbSession *s, const char *id, const char *params_json);
char *pcb_inspect(const PcbSession *s);
char *pcb_checks(const PcbSession *s);
char *pcb_commands(void);

// Board to 3D link (viaform-core): replies {"ok": ...} or {"error": ...}
char *vf_link_push(ScSession *sc, const PcbSession *pcb);
char *vf_link_mount(ScSession *sc, const PcbSession *pcb, const char *body, const double *point3, const double *normal3);
int64_t vf_link_revision(ScSession *sc, const PcbSession *pcb);

#endif
