// A flying drone end to end: the airframe in the design, the flight controller in the
// electronics, the routed board seated on the frame, the checks a drone needs before it flies,
// then STEP, KiCad and the .viaform file. drone.ts builds it; this asserts every stage.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as drone from "./drone";

// eslint-disable-next-line @typescript-eslint/no-require-imports
const native = require(path.join(__dirname, "..", "..", "native", "viaform.node"));

test("drone: frame, flight controller, board on the frame, flight checks, exports", async (t) => {
  const w = new native.Workspace(false);

  await t.test("airframe and assembly", () => {
    drone.buildAirframe(w);
    const joints = drone.assemble(w);
    assert.equal(joints.length, 4);
    const listed = w.cad("joint.list", {}).joints as { name: string; error?: string | null }[];
    for (const name of joints) assert.ok(listed.some((j) => j.name === name && !j.error), `${name} is healthy`);
    const tl = w.cad("document.inspect", {}).timeline as { name: string; error?: string | null }[];
    assert.deepEqual(tl.filter((f) => f.error).map((f) => f.name), []);
  });

  await t.test("flight controller: schematic, board, routing", () => {
    drone.buildFlightController(w);
    const p = w.pcbInspect().project;
    assert.equal(p.components.length, 12);
    assert.equal(p.board.footprints.length, 12);
    assert.equal(p.board.cutouts.length, 4);
    assert.equal(p.nets.length, 12);
    assert.deepEqual(w.pcbChecks().erc, []);

    const r = drone.routeBoard(w);
    assert.deepEqual(r.failed, []);
    const checks = w.pcbChecks();
    assert.equal(checks.airwires.length, 0, "every net is routed");
    assert.deepEqual(checks.drc.map((f: { message: string }) => f.message), [], "clearances, edge and holes are clean");
  });

  await t.test("board seated on the frame", () => {
    const m = drone.mountBoard(w);
    assert.equal(m.host, "Frame:1");
    assert.equal(w.linkState().out_of_date, false);
    const bodies = w.scene().meshes.map((x: { body: string }) => x.body);
    for (const b of ["Frame", "Battery", "Prop1", "PCB Board", "PCB U1"]) assert.ok(bodies.includes(b), b);
  });

  await t.test("flight checks", () => {
    const r = drone.flightChecks(w);
    t.diagnostic(`mass ${r.massG.toFixed(1)} g, T/W ${r.thrustToWeight.toFixed(2)}, CoM ${r.centreOfMass.map((v) => v.toFixed(2)).join(", ")} mm`);
    // A 5-inch quad on a 4S pack weighs 350 to 700 g ready to fly.
    assert.ok(r.massG > 350 && r.massG < 700, `mass ${r.massG} g`);
    // Balanced over the middle of the motors, so no motor works harder in a hover.
    assert.ok(Math.hypot(r.centreOfMass[0], r.centreOfMass[1]) < 1, "centre of mass on the thrust axis");
    assert.ok(r.thrustToWeight >= 2, "enough thrust to climb and manoeuvre");
    assert.equal(r.interferences, 0, "no part overlaps another");
    assert.equal(r.spin.truncated, false);
    assert.equal(r.spin.collisions, 0, "propellers clear the frame, pack and board over a full turn");
    assert.ok(r.spin.clear);
  });

  await t.test("STEP, KiCad and the project round trip", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "viaform-drone-"));
    const step = path.join(dir, "drone.step");
    w.cad("file.export_step", { path: step });
    const text = fs.readFileSync(step, "utf8");
    assert.match(text, /^ISO-10303-21;/);
    assert.match(text, /Frame/);

    const kicad = path.join(dir, "flight-controller.kicad_pcb");
    w.pcb("file.export_kicad", { path: kicad });
    const board = fs.readFileSync(kicad, "utf8");
    assert.match(board, /^\(kicad_pcb/);
    assert.match(board, /\(net \d+ "?SDA"?\)/);

    const file = path.join(dir, "drone.viaform");
    w.save(file);
    const back = new native.Workspace(false);
    back.open(file);
    assert.deepEqual(back.pcbInspect().project, w.pcbInspect().project);
    assert.equal(back.linkState().out_of_date, false);
    assert.equal(back.cad("joint.list", {}).joints.length, w.cad("joint.list", {}).joints.length);
  });
});

test("drone: the spin check catches a part in a propeller's path", () => {
  // Without this, a spin check that never reports anything would pass the test above.
  const w = new native.Workspace(false);
  drone.buildAirframe(w);
  const [x, y] = drone.motorAt(0);
  // A camera block on the arm, inside the propeller disc, at blade height.
  w.cad("solid.box", { length: 20, width: 20, height: 20, center: [x * 0.6, y * 0.6, 20], body_name: "Camera" });
  drone.assemble(w);
  w.cad("component.from_bodies", { bodies: ["Camera"] });
  w.cad("joint.rigid_group", { occurrences: ["Frame:1", "Camera:1"] });
  const r = drone.flightChecks(w);
  assert.ok(r.spin.collisions > 0, "Prop1 hits the camera");
});
