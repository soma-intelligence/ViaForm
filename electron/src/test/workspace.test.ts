// End to end over the addon the app ships: one workspace, the PCB flow, the board in 3D, and the
// .viaform file. Runs under plain Node (`npm test`), the same N-API binary Electron loads.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// eslint-disable-next-line @typescript-eslint/no-require-imports
const native = require(path.join(__dirname, "..", "..", "native", "viaform.node"));

test("versions name every engine", () => {
  const v = native.versions();
  assert.ok(v.core && v.solidcraft && v.pcbcraft);
  assert.equal(v.format, 1);
});

test("schematic to board to routes to KiCad", () => {
  const w = new native.Workspace(false);
  const r1 = w.pcb("component.add", { kind: "resistor", position: { x: 10, y: 10 } }).result;
  const d1 = w.pcb("component.add", { kind: "led", position: { x: 30, y: 10 } }).result;
  const parts = w.pcbInspect().project.components;
  const pin = (id: number, i: number) => parts.find((c: { id: number }) => c.id === id).pins[i].number;
  w.pcb("wire.connect", { from: { component: r1.id, pin: pin(r1.id, 1) }, to: { component: d1.id, pin: pin(d1.id, 0) } });
  w.pcb("board.sync");
  assert.equal(w.pcbInspect().project.board.footprints.length, 2);
  assert.ok(w.pcbChecks().airwires.length > 0);
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "viaform-")), "b.kicad_pcb");
  w.pcb("file.export_kicad", { path: file });
  assert.match(fs.readFileSync(file, "utf8"), /^\(kicad_pcb/);
  assert.throws(() => w.cad("no.such.command"), /unknown command/);
});

test("board in 3D follows the electronics and the project round trips", () => {
  const w = new native.Workspace(true);
  w.cad("solid.box", { length: 80, width: 60, height: 10, corner: [-10, -50, 0], body_name: "Enclosure" });
  assert.equal(w.linkPush().created, true);
  w.linkMount("Enclosure", [30, -20, 10], [0, 0, 1]);
  const bodies = w.scene().meshes.map((m: { body: string }) => m.body);
  assert.ok(bodies.includes("PCB Board") && bodies.includes("Enclosure"));

  w.pcb("component.add", { kind: "capacitor", position: { x: 50, y: 30 } });
  assert.equal(w.linkState().out_of_date, true);
  assert.equal(w.linkPush().created, false);
  assert.equal(w.linkState().out_of_date, false);

  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "viaform-")), "p.viaform");
  w.save(file);
  const back = new native.Workspace(false);
  back.open(file);
  assert.deepEqual(back.pcbInspect().project, w.pcbInspect().project);
  assert.equal(back.linkState().linked_revision !== null, true);
  assert.ok(back.scene().meshes.some((m: { body: string }) => m.body === "Enclosure"));
});
