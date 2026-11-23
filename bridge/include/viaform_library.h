#ifndef VIAFORM_LIBRARY_H
#define VIAFORM_LIBRARY_H

// Side libraries (viaform-library): KiCad on this Mac, standard hardware, distributor and
// marketplace APIs, saved parts. Replies are JSON {"ok": ...} or {"error": ...}, freed with
// sc_string_free. API keys are passed with each search, read from the Keychain by the app.

typedef struct VfLibrary VfLibrary;

VfLibrary *vf_library_open(const char *dir);
void vf_library_free(VfLibrary *lib);
// Blocking (searches reach the network): call off the main thread, one call at a time.
char *vf_library_call(VfLibrary *lib, const char *method, const char *params_json);

#endif
