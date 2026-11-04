// The flight controller: a cascade of PID loops as on Betaflight, INAV and PX4. Position gives a
// velocity setpoint, velocity gives an acceleration (and so a thrust vector and an attitude),
// attitude gives body rates, rates give torques, and the mixer turns thrust and torques into
// four motor speeds. A learned residual (policy.ts) can add to the acceleration command.

import { add, clamp, clampLen, col, cross, dot, mtv, norm, qToM3, scale, sub, unit, type M3, type V3 } from "./math";
import { G, MOTOR_SPIN, motorPositions, type QuadParams } from "./physics";

/** Every gain the tuner may change, in one flat record. */
export type Gains = {
  posP: number; // 1/s
  velP: number; // 1/s
  velI: number; // 1/s²
  velD: number; // dimensionless
  attP: number; // 1/s
  yawP: number; // 1/s
  rateP: number; // 1/s
  rateI: number; // 1/s²
  rateD: number; // dimensionless
  yawRateP: number; // 1/s
};

export const DEFAULT_GAINS: Gains = { posP: 1.2, velP: 2.2, velI: 0.6, velD: 0.05, attP: 7, yawP: 3, rateP: 22, rateI: 30, rateD: 0.02, yawRateP: 10 };
export const GAIN_KEYS = Object.keys(DEFAULT_GAINS) as (keyof Gains)[];

export type Limits = { tiltMax: number; velMax: number; velUpMax: number; accMax: number; rateMax: number; yawRateMax: number };
export const DEFAULT_LIMITS: Limits = { tiltMax: (40 * Math.PI) / 180, velMax: 5, velUpMax: 2.5, accMax: 12, rateMax: 8, yawRateMax: 3 };

/** What the controller knows about the drone: an estimate, not the true state. */
export type Estimate = { p: V3; v: V3; R: M3; w: V3; accBody: V3 };

export type Setpoint =
  | { mode: "position"; p: V3; yaw: number }
  | { mode: "velocity"; v: V3; yaw: number; p?: V3 };

export class Cascade {
  velInt: V3 = [0, 0, 0];
  rateInt: V3 = [0, 0, 0];
  lastVelErr: V3 = [0, 0, 0];
  wFilt: V3 = [0, 0, 0];
  lastW: V3 = [0, 0, 0];
  /** For the policy and the display: the last acceleration command and collective thrust. */
  accCmd: V3 = [0, 0, 0];
  thrustCmd = 0;
  private mixInv: number[][];

  constructor(public P: QuadParams, public g: Gains = { ...DEFAULT_GAINS }, public lim: Limits = { ...DEFAULT_LIMITS }) {
    this.mixInv = mixerInverse(P);
  }

  reset(): void {
    this.velInt = [0, 0, 0];
    this.rateInt = [0, 0, 0];
    this.lastVelErr = [0, 0, 0];
    this.wFilt = [0, 0, 0];
    this.lastW = [0, 0, 0];
  }

  /** The acceleration the outer loops ask for (before any learned residual). */
  outer(e: Estimate, sp: Setpoint, dt: number): V3 {
    const g = this.g, L = this.lim;
    let vSp: V3;
    if (sp.mode === "position") vSp = scale(sub(sp.p, e.p), g.posP);
    else vSp = sp.p ? add(sp.v, scale(sub(sp.p, e.p), g.posP * 0.5)) : sp.v;
    const h = clampLen([vSp[0], vSp[1], 0], L.velMax);
    vSp = [h[0], h[1], clamp(vSp[2], -L.velUpMax, L.velUpMax)];

    const err = sub(vSp, e.v);
    const dErr = scale(sub(err, this.lastVelErr), 1 / dt);
    this.lastVelErr = err;
    let a = add(add(scale(err, g.velP), this.velInt), scale(dErr, g.velD));
    // Anti-windup: integrate only while the command is not saturated.
    if (norm(a) < L.accMax) this.velInt = clampLen(add(this.velInt, scale(err, g.velI * dt)), 6);
    a = clampLen(a, L.accMax);
    return a;
  }

  /** Motor speed commands from an acceleration command (world) and a yaw setpoint. */
  inner(e: Estimate, acc: V3, yawSp: number, dt: number): number[] {
    const P = this.P, g = this.g, L = this.lim;
    this.accCmd = acc;
    // Thrust vector: what must push against gravity plus the commanded acceleration, tilt limited.
    let f: V3 = [acc[0], acc[1], Math.max(acc[2] + G, 0.25 * G)];
    const horiz = Math.hypot(f[0], f[1]), maxH = f[2] * Math.tan(L.tiltMax);
    if (horiz > maxH) f = [(f[0] * maxH) / horiz, (f[1] * maxH) / horiz, f[2]];
    const zb = unit(f);
    const collective = P.mass * dot(f, col(e.R, 2));
    this.thrustCmd = collective;

    // Desired attitude from the thrust axis and the yaw setpoint.
    const xc: V3 = [Math.cos(yawSp), Math.sin(yawSp), 0];
    const yb = unit(cross(zb, xc));
    const xb = cross(yb, zb);
    const Rd: M3 = [xb[0], yb[0], zb[0], xb[1], yb[1], zb[1], xb[2], yb[2], zb[2]];
    // Geometric attitude error eR = ½ vee(Rdᵀ R − Rᵀ Rd).
    const m = (A: M3, B: M3, i: number, j: number) => A[0 * 3 + i] * B[0 * 3 + j] + A[1 * 3 + i] * B[1 * 3 + j] + A[2 * 3 + i] * B[2 * 3 + j];
    const eR: V3 = [
      0.5 * (m(Rd, e.R, 2, 1) - m(e.R, Rd, 2, 1)),
      0.5 * (m(Rd, e.R, 0, 2) - m(e.R, Rd, 0, 2)),
      0.5 * (m(Rd, e.R, 1, 0) - m(e.R, Rd, 1, 0)),
    ];
    // Yaw is slow on a quad (only drag torque turns it): cap it so it never eats the motors'
    // headroom that roll and pitch need.
    const wSp: V3 = [clamp(-g.attP * eR[0], -L.rateMax, L.rateMax), clamp(-g.attP * eR[1], -L.rateMax, L.rateMax), clamp(-g.yawP * eR[2], -L.yawRateMax, L.yawRateMax)];

    // Rate loop, D on the measurement through a low-pass (gyro noise).
    this.wFilt = add(scale(this.wFilt, 0.7), scale(e.w, 0.3));
    const dW = scale(sub(this.wFilt, this.lastW), 1 / dt);
    this.lastW = this.wFilt;
    const rErr = sub(wSp, e.w);
    this.rateInt = clampLen(add(this.rateInt, scale(rErr, g.rateI * dt)), 3);
    const J = P.inertia;
    const alpha: V3 = [
      g.rateP * rErr[0] + this.rateInt[0] - g.rateD * dW[0] * 100,
      g.rateP * rErr[1] + this.rateInt[1] - g.rateD * dW[1] * 100,
      g.yawRateP * rErr[2] + 0.2 * this.rateInt[2],
    ];
    const Jw: V3 = [J[0] * e.w[0], J[1] * e.w[1], J[2] * e.w[2]];
    const tau = add([J[0] * alpha[0], J[1] * alpha[1], J[2] * alpha[2]], cross(e.w, Jw));
    return this.mix(collective, tau);
  }

  /** Thrust per motor from collective and torques; yaw gives way first when a motor saturates. */
  mix(collective: number, tau: V3): number[] {
    const P = this.P;
    const tMax = P.kT * P.omegaMax * P.omegaMax, tMin = P.kT * P.omegaIdle * P.omegaIdle;
    const solve = (u: number[]) => this.mixInv.map((row) => row.reduce((s, k, j) => s + k * u[j], 0));
    let T = solve([collective, tau[0], tau[1], tau[2]]);
    if (Math.max(...T) > tMax || Math.min(...T) < tMin) T = solve([collective, tau[0], tau[1], tau[2] * 0.3]);
    // Air mode: shift all four to keep the differential (attitude authority) inside the range.
    const hi = Math.max(...T), lo = Math.min(...T);
    if (hi - lo <= tMax - tMin) {
      const shift = hi > tMax ? tMax - hi : lo < tMin ? tMin - lo : 0;
      T = T.map((t) => t + shift);
    }
    return T.map((t) => Math.sqrt(clamp(t, tMin, tMax) / P.kT));
  }
}

/** Inverse of the map from motor thrusts to [collective, roll, pitch, yaw torque]. */
export function mixerInverse(P: QuadParams): number[][] {
  const pos = motorPositions(P);
  const A = [
    [1, 1, 1, 1],
    pos.map((r) => r[1]),
    pos.map((r) => -r[0]),
    MOTOR_SPIN.map((s) => (s * P.kQ) / P.kT),
  ];
  return invert4(A);
}

function invert4(A: number[][]): number[][] {
  const n = 4;
  const M = A.map((row, i) => [...row, ...Array.from({ length: n }, (_, j) => (i === j ? 1 : 0))]);
  for (let c = 0; c < n; c++) {
    let p = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
    [M[c], M[p]] = [M[p], M[c]];
    const d = M[c][c];
    for (let j = 0; j < 2 * n; j++) M[c][j] /= d;
    for (let r = 0; r < n; r++) {
      if (r === c) continue;
      const k = M[r][c];
      for (let j = 0; j < 2 * n; j++) M[r][j] -= k * M[c][j];
    }
  }
  return M.map((row) => row.slice(n));
}

/** Yaw of the body x axis (rad). */
export const headingOf = (R: M3) => Math.atan2(R[3], R[0]);
/** Body-frame vector of a world vector. */
export const toBody = (R: M3, v: V3) => mtv(R, v);
export { qToM3 };
