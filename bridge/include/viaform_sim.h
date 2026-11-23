// The drone simulation (viaform-sim): one handle per flight, JSON text both ways.
// Every returned string is freed with sc_string_free.
#ifndef VIAFORM_SIM_H
#define VIAFORM_SIM_H

#include <stdbool.h>

typedef struct VfSim VfSim;

char *vf_sim_catalog(void);
char *vf_sim_parts(double frame_g);
// Runs a whole flight off to the side: {"crashed", "completed", "recoveries", ...}
char *vf_sim_episode(const char *options_json);

// Null when the options do not parse.
VfSim *vf_sim_start(const char *options_json);
void vf_sim_free(VfSim *sim);
char *vf_sim_world(const VfSim *sim);
char *vf_sim_advance(VfSim *sim, double seconds);
// kind: kick, gust, tumble, payload, prop, or timed (toggles random ones)
bool vf_sim_disturb(VfSim *sim, const char *kind);
// sticks: {"x","y","z","yaw"} each -1..1, optional "mode": "position" | "angle"
bool vf_sim_pilot(VfSim *sim, const char *sticks_json);
// What a generated frame file builds: {name, frameG, armMm, massKg, inertia, thrustToWeight} or {error}
char *vf_sim_airframe(const char *frame_json);
// What the sourced components build: request {"components", "assembly"?, "frame"?} (file texts)
char *vf_sim_vehicle(const char *request_json);

// Training on background threads: poll progress, cancel, free (free cancels and waits).
typedef struct VfTrain VfTrain;
VfTrain *vf_train_start(const char *options_json);
char *vf_train_progress(const VfTrain *job);
void vf_train_cancel(const VfTrain *job);
void vf_train_free(VfTrain *job);

#endif
