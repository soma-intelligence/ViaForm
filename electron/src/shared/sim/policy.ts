// The learned part of the controller: a small neural network that adds a correction to the
// acceleration the PID cascade asks for. It sees what the PID loops see plus an estimate of the
// outside force (what the accelerometer measures minus what the motors were told to push), so it
// can learn to cancel gusts before the integrator catches up. Trained by evolution strategies
// (train.ts), the reinforcement learning method of Salimans et al. 2017: no gradients of the
// simulator needed, and the same reward as any RL setup.

import { clamp, type V3 } from "./math";

export const POLICY_INPUTS = 17;
export const POLICY_HIDDEN = 16;
export const POLICY_OUTPUTS = 3;
export const POLICY_SIZE = POLICY_INPUTS * POLICY_HIDDEN + POLICY_HIDDEN + POLICY_HIDDEN * POLICY_OUTPUTS + POLICY_OUTPUTS;
/** Largest correction (m/s²) the network may add on each axis. */
export const POLICY_AUTHORITY = 4;

export class Policy {
  constructor(public theta: Float64Array = new Float64Array(POLICY_SIZE)) {}

  /** All inputs in the heading frame (yaw removed), so what it learns does not depend on which
   *  way the drone faces. */
  act(x: number[]): V3 {
    const th = this.theta;
    const h = new Float64Array(POLICY_HIDDEN);
    let k = 0;
    for (let j = 0; j < POLICY_HIDDEN; j++) {
      let s = 0;
      for (let i = 0; i < POLICY_INPUTS; i++) s += th[k++] * x[i];
      h[j] = s;
    }
    for (let j = 0; j < POLICY_HIDDEN; j++) h[j] = Math.tanh(h[j] + th[k++]);
    const out: V3 = [0, 0, 0];
    for (let o = 0; o < POLICY_OUTPUTS; o++) {
      let s = 0;
      for (let j = 0; j < POLICY_HIDDEN; j++) s += th[k++] * h[j];
      out[o] = s;
    }
    for (let o = 0; o < POLICY_OUTPUTS; o++) out[o] = POLICY_AUTHORITY * Math.tanh(out[o] + th[k++]);
    return out;
  }

  toJSON(): number[] {
    return Array.from(this.theta, (v) => Math.round(v * 1e5) / 1e5);
  }
  static from(values: number[] | null | undefined): Policy | null {
    return values && values.length === POLICY_SIZE ? new Policy(Float64Array.from(values)) : null;
  }
}

/** The network's input vector. Everything rotated into the heading frame (c, s: cos and sin of
 *  the heading) and scaled to about unit size. */
export function policyInput(o: {
  velErr: V3; v: V3; force: V3; tilt: [number, number]; w: V3; velInt: V3; heading: number;
}): number[] {
  const c = Math.cos(o.heading), s = Math.sin(o.heading);
  const h = (a: V3, k: number): number[] => [clamp((c * a[0] + s * a[1]) * k, -3, 3), clamp((-s * a[0] + c * a[1]) * k, -3, 3), clamp(a[2] * k, -3, 3)];
  return [...h(o.velErr, 0.5), ...h(o.v, 0.25), ...h(o.force, 0.2), o.tilt[0] * 2, o.tilt[1] * 2, ...o.w.map((x) => clamp(x * 0.3, -3, 3)), ...h(o.velInt, 0.3)];
}
