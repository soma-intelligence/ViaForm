// Generative design over the addon the app ships: a cantilever study with two variants, then its
// best candidate built into the design as one body and one undo step.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as path from "node:path";

// eslint-disable-next-line @typescript-eslint/no-require-imports
const native = require(path.join(__dirname, "..", "..", "native", "viaform.node"));

/** A 120 x 40 mm plate held along its left edge, pulled down at the middle of its right edge. */
const cantilever = {
  method: "topology",
  width: 120,
  height: 40,
  thickness: 6,
  resolution: 4,
  iterations: 30,
  volume_fraction: 0.4,
  variants: 2,
  supports: [{ region: { shape: "rect", min: [0, 0], max: [1, 40] }, fix: "all" }],
  cases: [{ name: "tip", loads: [{ region: { shape: "circle", center: [120, 20], radius: 2 }, force: [0, -500] }] }],
  body_name: "Bracket",
};

const bodies = (w: { scene(): { meshes: { body: string }[] } }) => w.scene().meshes.map((m) => m.body);

test("generative: a cantilever study, its best candidate built as one body", () => {
  const out = native.generateStudy(cantilever) as { candidates: { id: number; mass_g: number }[]; best: number };
  assert.equal(out.candidates.length, 2);
  assert.ok(out.best >= 0 && out.best < 2);

  const w = new native.Workspace(false);
  const r = w.generate(cantilever) as { body: string; commands: number; candidate: { id: number; shape?: unknown } };
  assert.equal(r.body, "Bracket");
  assert.equal(r.candidate.id, out.best);
  assert.equal(r.candidate.shape, undefined);
  assert.ok(r.commands > 0);
  assert.ok(bodies(w).includes("Bracket"));

  w.cad("edit.undo", {});
  assert.ok(!bodies(w).includes("Bracket"), "the whole build is one undo step");
});

test("generative: a refused spec throws and leaves the design alone", () => {
  const w = new native.Workspace(false);
  assert.throws(() => w.generate({ ...cantilever, supports: [] }), /support/);
  assert.deepEqual(bodies(w), []);
});
