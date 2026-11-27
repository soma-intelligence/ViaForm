// `npm run sample:drone`: builds the drone of drone.test.ts and writes it to samples/ as
// drone.viaform (open it in the app), drone.step and flight-controller.kicad_pcb.
import * as fs from "node:fs";
import * as path from "node:path";
import * as drone from "./drone";

// eslint-disable-next-line @typescript-eslint/no-require-imports
const native = require(path.join(__dirname, "..", "..", "native", "viaform.node"));

const out = path.resolve(__dirname, "..", "..", "..", "samples");
fs.mkdirSync(out, { recursive: true });
const w = new native.Workspace(false);
drone.buildAirframe(w);
drone.assemble(w);
drone.buildFlightController(w);
const routed = drone.routeBoard(w);
drone.mountBoard(w);
const report = drone.flightChecks(w);
w.cad("file.export_step", { path: path.join(out, "drone.step") });
w.pcb("file.export_kicad", { path: path.join(out, "flight-controller.kicad_pcb") });
w.save(path.join(out, "drone.viaform"));
console.log(JSON.stringify({ routed, report }, null, 2));
console.log(`Wrote ${out}/drone.viaform, drone.step and flight-controller.kicad_pcb`);
