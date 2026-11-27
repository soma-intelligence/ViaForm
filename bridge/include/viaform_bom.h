#ifndef VIAFORM_BOM_H
#define VIAFORM_BOM_H

// Bill of materials (viaform-bom): one BOM per project, from the design, the PCB and component
// files, rolled up for N builds. Replies are JSON {"ok": ...} or {"error": ...}, freed with
// sc_string_free. Prices refresh through vf_library_call("search"), then "apply_hits" here.

typedef struct VfBom VfBom;
typedef struct ScSession ScSession;
typedef struct PcbSession PcbSession;

VfBom *vf_bom_new(void);
void vf_bom_free(VfBom *bom);
// sc and pcb may be null for calls that do not read the design or the board
// (sync_design, sync_pcb, save_project, open_project do).
char *vf_bom_call(VfBom *bom, ScSession *sc, PcbSession *pcb, const char *method, const char *params_json);

#endif
