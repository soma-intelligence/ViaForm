// Rigid-body flight model of an X quadcopter: four motors with first-order spin-up, thrust and
// drag torque from the propeller speed, body and rotor drag against the air (not the ground),
// gravity, ground contact, and a wind field with a mean, turbulence and gusts. World frame is
// x east, y north, z up; body frame is x forward, y left, z up. SI units throughout.

import { add, cross, mtv, mv, qMul, qNormalize, qToM3, scale, sub, type Q, type Rng, type V3 } from "./math";

export type QuadParams = {
  mass: number; // kg, all-up
  inertia: V3; // kg·m², principal, body axes
  arm: number; // m, centre to motor axis
  kT: number; // N per (rad/s)², thrust = kT ω²
  kQ: number; // N·m per (rad/s)², drag torque = kQ ω²
  omegaMax: number; // rad/s at full throttle on a charged pack
  omegaIdle: number; // rad/s, motors never stop in the air (air mode)
  motorTau: number; // s, first-order spin-up time constant
  dragLinear: V3; // N per m/s in body axes (rotor induced drag dominates horizontally)
  dragQuad: V3; // N per (m/s)² in body axes (frame and pack)
  propRadius: number; // m, for collision and drawing
  bodyRadius: number; // m, collision sphere of the airframe with propellers
};

/** Motor i at body angle MOTOR_ANGLES[i] (deg from forward, counter-clockwise), spin sign
 *  MOTOR_SPIN[i] (+1: reaction torque along +z). Front right, front left, back left, back right. */
export const MOTOR_ANGLES = [-45, 45, 135, -135];
export const MOTOR_SPIN = [1, -1, 1, -1];

export type QuadState = {
  p: V3;
  v: V3;
  q: Q;
  w: V3; // body rates
  omega: [number, number, number, number];
  t: number;
  crashed: boolean;
  /** Last specific force in body axes (what an accelerometer measures). */
  accBody: V3;
};

export const newState = (p: V3 = [0, 0, 0], q: Q = [1, 0, 0, 0]): QuadState => ({
  p: [...p] as V3, v: [0, 0, 0], q: [...q] as Q, w: [0, 0, 0], omega: [0, 0, 0, 0], t: 0, crashed: false, accBody: [0, 0, 9.81],
});

export const G = 9.81;
export const RHO = 1.225;

/** Thrust of each motor in N at its current speed. */
export const thrusts = (P: QuadParams, s: QuadState) => s.omega.map((o) => P.kT * o * o) as [number, number, number, number];

export function motorPositions(P: QuadParams): V3[] {
  return MOTOR_ANGLES.map((a) => [P.arm * Math.cos((a * Math.PI) / 180), P.arm * Math.sin((a * Math.PI) / 180), 0] as V3);
}

// MARK: Wind

export type WindSpec = {
  mean: V3; // m/s
  turbulence: number; // m/s, standard deviation per axis
  lengthScale: number; // m, size of the eddies (sets the turbulence bandwidth with airspeed)
  gustEvery: number; // s, mean time between gusts (0: none)
  gustPeak: number; // m/s
};
export const CALM: WindSpec = { mean: [0, 0, 0], turbulence: 0, lengthScale: 10, gustEvery: 0, gustPeak: 0 };

/** Mean plus Dryden-like turbulence (a first-order filtered noise per axis whose bandwidth grows
 *  with airspeed) plus discrete 1 − cos gusts from random directions. */
export class Wind {
  turb: V3 = [0, 0, 0];
  gust: { start: number; length: number; dir: V3; peak: number } | null = null;
  nextGust: number;
  constructor(public spec: WindSpec, private rand: Rng) {
    this.nextGust = spec.gustEvery ? rand.range(0.3, 1.7) * spec.gustEvery : Infinity;
  }
  at(t: number, dt: number, airspeed: number): V3 {
    const s = this.spec;
    if (s.turbulence > 0) {
      const a = Math.max(airspeed, 2) * dt / s.lengthScale; // inverse correlation time × dt
      const k = Math.sqrt(2 * a) * s.turbulence;
      for (let i = 0; i < 3; i++) this.turb[i] += -a * this.turb[i] + k * this.rand.gauss() * (i === 2 ? 0.5 : 1);
    }
    if (!this.gust && t >= this.nextGust) {
      const yaw = this.rand.range(0, 2 * Math.PI);
      this.gust = { start: t, length: this.rand.range(0.6, 2), dir: [Math.cos(yaw), Math.sin(yaw), this.rand.range(-0.2, 0.2)], peak: this.rand.range(0.5, 1) * s.gustPeak };
    }
    let g: V3 = [0, 0, 0];
    if (this.gust) {
      const u = (t - this.gust.start) / this.gust.length;
      if (u >= 1) {
        this.gust = null;
        this.nextGust = t + this.rand.range(0.3, 1.7) * s.gustEvery;
      } else g = scale(this.gust.dir, (this.gust.peak * (1 - Math.cos(2 * Math.PI * u))) / 2);
    }
    return add(add(s.mean, this.turb), g);
  }
}

// MARK: Step

/** The air and the airframe's condition for one step (weather.ts fills it). */
export type Env = {
  rho: number; // kg/m³
  thrustFactor: number; // water and ice on the blades
  extraMass: number; // kg, snow load
  downForce: number; // N, rain on the rotor discs
  omegaScale: number; // loaded pack voltage over a full pack's
};
export const SEA_LEVEL: Env = { rho: RHO, thrustFactor: 1, extraMass: 0, downForce: 0, omegaScale: 1 };

/** Ground effect (Cheeseman and Bennett): thrust gain of a rotor at height z over the ground. */
export const groundEffect = (propRadius: number, z: number) => 1 / (1 - Math.min(0.5, (propRadius / (4 * Math.max(z, 1e-3))) ** 2));

/**
 * Advances the state by dt toward the commanded motor speeds (rad/s), in the given wind.
 * Semi-implicit Euler: fine at the 1–2 ms steps the controller runs at.
 */
export function step(P: QuadParams, s: QuadState, cmd: number[], wind: V3, dt: number, env: Env = SEA_LEVEL): void {
  if (s.crashed) return;
  for (let i = 0; i < 4; i++) {
    const target = Math.min(Math.max(cmd[i], P.omegaIdle), P.omegaMax * env.omegaScale);
    s.omega[i] += (target - s.omega[i]) * Math.min(1, dt / P.motorTau);
  }
  const R = qToM3(s.q);
  const air = env.rho / RHO;
  const ge = groundEffect(P.propRadius, s.p[2] + 0.02);
  const T = thrusts(P, s).map((t) => t * air * env.thrustFactor * ge);
  const pos = motorPositions(P);
  const mass = P.mass + env.extraMass;

  // Forces in body axes: thrust along z, drag against the relative air.
  const rel = mtv(R, sub(s.v, wind));
  const thrust = T[0] + T[1] + T[2] + T[3];
  const drag: V3 = [0, 1, 2].map((i) => air * (-P.dragLinear[i] * rel[i] - P.dragQuad[i] * rel[i] * Math.abs(rel[i]))) as V3;
  const fBody: V3 = [drag[0], drag[1], thrust + drag[2] - env.downForce * R[8]];
  s.accBody = scale(fBody, 1 / mass);

  // Torques: differential thrust, propeller drag reaction, gyroscopic coupling.
  let tau: V3 = [0, 0, 0];
  for (let i = 0; i < 4; i++) {
    tau = add(tau, cross(pos[i], [0, 0, T[i]]));
    tau[2] += MOTOR_SPIN[i] * P.kQ * air * s.omega[i] * s.omega[i];
  }
  const J = P.inertia;
  const Jw: V3 = [J[0] * s.w[0], J[1] * s.w[1], J[2] * s.w[2]];
  const wdot = sub(tau, cross(s.w, Jw));
  s.w = [s.w[0] + (wdot[0] / J[0]) * dt, s.w[1] + (wdot[1] / J[1]) * dt, s.w[2] + (wdot[2] / J[2]) * dt];

  const a = add(scale(mv(R, fBody), 1 / mass), [0, 0, -G]);
  s.v = add(s.v, scale(a, dt));
  s.p = add(s.p, scale(s.v, dt));

  const [wx, wy, wz] = s.w;
  const dq: Q = qMul(s.q, [0, wx, wy, wz]);
  s.q = qNormalize([s.q[0] + 0.5 * dq[0] * dt, s.q[1] + 0.5 * dq[1] * dt, s.q[2] + 0.5 * dq[2] * dt, s.q[3] + 0.5 * dq[3] * dt]);

  // Ground: a soft landing stops on it, a hard or tilted one is a crash.
  if (s.p[2] < 0) {
    const tilted = R[8] < 0.7;
    if (s.v[2] < -3 || tilted || Math.hypot(s.v[0], s.v[1]) > 3) s.crashed = true;
    s.p[2] = 0;
    s.v = [0, 0, Math.max(0, s.v[2])];
    s.w = [0, 0, 0];
  }
  s.t += dt;
}
