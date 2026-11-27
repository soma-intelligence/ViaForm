import type { PilotInput } from "../shared/sim/sim";

// The game in the Simulation workspace: the sticks (keyboard or a gamepad) and the best times.
// The race itself (gates, pad, clock) is in src/shared/sim/race.ts.

/** Keyboard and gamepad to sticks. Keys ramp the sticks so a tap is a nudge, as a thumb is. */
export class Sticks {
  private keys = new Set<string>();
  private value: PilotInput = { x: 0, y: 0, z: 0, yaw: 0 };
  /** True while a gamepad moved last (the help card says which controls are live). */
  gamepad = false;

  /** Returns true when the key is a flight control. */
  key(code: string, down: boolean): boolean {
    if (!(code in KEYS)) return false;
    if (down) this.keys.add(code);
    else this.keys.delete(code);
    return true;
  }

  clear(): void {
    this.keys.clear();
    this.value = { x: 0, y: 0, z: 0, yaw: 0 };
  }

  read(dt: number): PilotInput {
    const pad = navigator.getGamepads?.().find((g) => g && g.connected);
    if (pad && pad.axes.length >= 4) {
      // Mode 2: left stick throttle and yaw, right stick pitch and roll.
      const a = (i: number) => (Math.abs(pad.axes[i]) < 0.08 ? 0 : pad.axes[i]);
      const u = { x: -a(3), y: -a(2), z: -a(1), yaw: -a(0) };
      if (Math.abs(u.x) + Math.abs(u.y) + Math.abs(u.z) + Math.abs(u.yaw) > 0) {
        this.gamepad = true;
        this.value = u;
        return u;
      }
    }
    const want: PilotInput = { x: 0, y: 0, z: 0, yaw: 0 };
    for (const k of this.keys) {
      const [axis, sign] = KEYS[k];
      want[axis] += sign;
    }
    const rate = 4 * dt;
    for (const axis of ["x", "y", "z", "yaw"] as const) {
      const target = Math.max(-1, Math.min(1, want[axis]));
      const d = target - this.value[axis];
      // Back to centre faster than away from it: releasing a key stops the drone promptly.
      const r = target === 0 ? rate * 2 : rate;
      this.value[axis] += Math.max(-r, Math.min(r, d));
    }
    if (this.keys.size) this.gamepad = false;
    return { ...this.value };
  }

  /** A gamepad's restart button (A / cross), edge-triggered. */
  private wasDown = false;
  restartPressed(): boolean {
    const pad = navigator.getGamepads?.().find((g) => g && g.connected);
    const down = !!pad?.buttons[0]?.pressed;
    const edge = down && !this.wasDown;
    this.wasDown = down;
    return edge;
  }
}

const KEYS: Record<string, [keyof PilotInput, number]> = {
  KeyW: ["x", 1], KeyS: ["x", -1], KeyA: ["y", 1], KeyD: ["y", -1],
  Space: ["z", 1], KeyC: ["z", -1], ArrowUp: ["z", 1], ArrowDown: ["z", -1],
  KeyQ: ["yaw", 1], KeyE: ["yaw", -1], ArrowLeft: ["yaw", 1], ArrowRight: ["yaw", -1],
};

export const CONTROLS_HELP = [
  ["W S", "forward, back"],
  ["A D", "left, right"],
  ["Space C  or  ↑ ↓", "up, down"],
  ["Q E  or  ← →", "turn"],
  ["Enter", "start again"],
];

/** Best times per weather and assist mode, kept in this browser only. */
export function bestTime(key: string): number | null {
  try {
    const v = localStorage.getItem(`viaform.sim.best.${key}`);
    return v ? Number(v) : null;
  } catch {
    return null;
  }
}

export function saveBest(key: string, t: number): boolean {
  const best = bestTime(key);
  if (best !== null && best <= t) return false;
  try {
    localStorage.setItem(`viaform.sim.best.${key}`, String(t));
  } catch {
    // Storage blocked: the time still shows, it is just not kept.
  }
  return true;
}
