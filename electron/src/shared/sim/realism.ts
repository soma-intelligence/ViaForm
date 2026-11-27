// What makes a small quad hard to hold still, beyond the rigid body in physics.ts. Each effect is
// a first-order model of a known phenomenon, sized for a 3-inch quad:
//   - Rotor drag and blade flapping: a rotor moving edgewise through the air makes a drag force
//     in the disc plane, proportional to its speed (Mahony, Kumar and Corke 2012). The rotors sit
//     above the centre of mass, so the force also pitches the drone back from the wind.
//   - Inflow: climbing through its own wake costs a rotor thrust, translational lift gives some
//     back in forward flight, and a fast vertical descent into the wake (vortex ring state) loses
//     thrust and makes it fluctuate rotor by rotor.
//   - Wind shear across the rotors: turbulence is not uniform over 12 cm. Each rotor sees its own
//     vertical gust, and the difference between them rolls and pitches the drone.
//   - The build: no two motors or props are alike (thrust, drag, spin-up), the centre of mass is
//     not at the centre of the motors, and props are out of balance, which shakes the frame at
//     the rotation frequency.
//   - The sensors: gyro and accelerometer noise and bias, bias drifting with temperature, motor
//     vibration on both (sampled at 8 kHz and averaged down to the loop rate, as a real flight
//     controller's gyro filter does), and the ESC's command latency.
// Kicks (a hit, a branch, a hand) are applied from outside with kick().

import { add, cross, mtv, scale, sub, type M3, type Rng, type V3 } from "./math";
import { MOTOR_ANGLES, type QuadParams, type QuadState } from "./physics";

export type Realism = {
  rotorDrag: number; // N per (m/s) per (rad/s) of rotor speed, in the disc plane
  rotorHeight: number; // m, rotor plane above the centre of mass
  inflow: boolean; // climb loss, translational lift, vortex ring state
  shear: number; // 0..1, share of the turbulence that differs from rotor to rotor
  motorSpread: number; // relative standard deviation of kT, kQ and spin-up between motors
  cgOffset: number; // m, standard deviation of the centre of mass from the centre of the motors
  imbalance: number; // N at full speed, prop and bell imbalance per motor
  gyroNoise: number; // rad/s per sample at the loop rate
  gyroBiasWalk: number; // rad/s per √s
  accNoise: number; // m/s² per sample
  escDelay: number; // loop steps between a command and the ESC acting on it
};

/** All effects at the size measured on 3-inch builds. */
export const REALISTIC: Realism = {
  rotorDrag: 5.8e-6, rotorHeight: 0.012, inflow: true, shear: 0.6, motorSpread: 0.04, cgOffset: 0.004, imbalance: 0.05,
  gyroNoise: 0.02, gyroBiasWalk: 0.002, accNoise: 0.25, escDelay: 1,
};
/** None of them: the rigid body alone (what the first training ran on). */
export const IDEAL: Realism = {
  rotorDrag: 0, rotorHeight: 0, inflow: false, shear: 0, motorSpread: 0, cgOffset: 0, imbalance: 0,
  gyroNoise: 0.03, gyroBiasWalk: 0, accNoise: 0.3, escDelay: 0,
};

/** One drone as built: its motors and its balance. */
export type Build = {
  kT: [number, number, number, number]; // scale per motor
  kQ: [number, number, number, number];
  tau: [number, number, number, number];
  cg: V3; // m, body axes
  phase: [number, number, number, number]; // rad, imbalance phase per motor
};

export function makeBuild(R: Realism, rand: Rng): Build {
  const spread = () => [0, 1, 2, 3].map(() => 1 + R.motorSpread * Math.max(-2.5, Math.min(2.5, rand.gauss()))) as Build["kT"];
  return {
    kT: spread(), kQ: spread(), tau: spread(),
    cg: [R.cgOffset * rand.gauss(), R.cgOffset * rand.gauss(), 0],
    phase: [0, 1, 2, 3].map(() => rand.range(0, 2 * Math.PI)) as Build["phase"],
  };
}

/** Hover induced velocity (m/s) of one rotor making thrust T: momentum theory. */
export const inducedVelocity = (T: number, rho: number, radius: number) => Math.sqrt(Math.max(T, 1e-4) / (2 * rho * Math.PI * radius * radius));

/**
 * Thrust factor of one rotor from its inflow: `vz` is the air coming up through the disc in body
 * z (positive in a descent), `vh` the edgewise airspeed, `vi` the hover induced velocity. Climb
 * (vz < 0) costs thrust, edgewise flow adds some (translational lift), and a descent between
 * about 0.4 and 1.6 vi with little edgewise flow is the vortex ring state: thrust falls by up to
 * 30 % and flutters (the caller adds the flutter).
 */
export function inflowFactor(vz: number, vh: number, vi: number): { factor: number; vrs: number } {
  // Descending into the wake helps only a little before the ring forms.
  const climb = Math.max(-0.4, Math.min(0.1, vz / (2 * vi)));
  const etl = 0.12 * Math.min(1, (vh / (1.5 * vi)) ** 2);
  const d = vz / vi;
  // VRS: a bump around 1 vi of descent, washed out by edgewise flow.
  const vrs = Math.max(0, 1 - ((d - 1) / 0.6) ** 2) * Math.max(0, 1 - vh / vi);
  return { factor: (1 + climb) * (1 + etl) * (1 - 0.3 * vrs), vrs };
}

/** The extra forces and torques (body axes) of the effects above, for one physics step. */
export class Aero {
  /** Vertical gust at each rotor relative to the mean turbulence (m/s), an OU process. */
  shearW: [number, number, number, number] = [0, 0, 0, 0];
  flutter: [number, number, number, number] = [0, 0, 0, 0];
  vrs = 0;
  phase: [number, number, number, number];
  /** Last imbalance force (body), for the accelerometer. */
  shake: V3 = [0, 0, 0];

  constructor(public R: Realism, public build: Build, private rand: Rng) {
    this.phase = [...build.phase];
  }

  /**
   * Thrust per rotor after the build's spread, inflow, shear and flutter, plus the in-plane forces
   * of rotor drag and imbalance and their torques about the centre of mass (body axes). `T` is
   * each rotor's nominal thrust, `rel` the body-axes velocity of the drone through the air,
   * `turbulence` the turbulence intensity (m/s). The caller applies the thrusts at the motor
   * positions; `torque` adds what the centre-of-mass offset and the in-plane forces make.
   */
  forces(P: QuadParams, s: QuadState, T: number[], rel: V3, rho: number, turbulence: number, dt: number): { T: number[]; force: V3; torque: V3 } {
    const R = this.R, b = this.build;
    const out = T.map((t, i) => t * b.kT[i]);
    let force: V3 = [0, 0, 0], torque: V3 = [0, 0, 0];
    const pos = MOTOR_ANGLES.map((a) => [P.arm * Math.cos((a * Math.PI) / 180) - b.cg[0], P.arm * Math.sin((a * Math.PI) / 180) - b.cg[1], R.rotorHeight - b.cg[2]] as V3);
    // Shear: each rotor's own vertical gust, decorrelating over a few arm lengths of travel.
    if (R.shear > 0 && turbulence > 0) {
      const airspeed = Math.max(2, Math.hypot(rel[0], rel[1], rel[2]));
      const a = Math.min(1, (airspeed * dt) / (P.arm * 4));
      const sd = R.shear * turbulence * 0.5;
      for (let i = 0; i < 4; i++) this.shearW[i] += -a * this.shearW[i] + Math.sqrt(2 * a) * sd * this.rand.gauss();
    } else this.shearW = [0, 0, 0, 0];
    this.vrs = 0;
    this.shake = [0, 0, 0];
    const af = Math.min(1, dt / 0.05);
    for (let i = 0; i < 4; i++) {
      const r = pos[i];
      // Air at the rotor: the drone's motion, its rotation (w × r), and its own gust.
      const local = add(sub(rel, [0, 0, this.shearW[i]]), cross(s.w, r));
      const vh = Math.hypot(local[0], local[1]);
      if (R.inflow) {
        const vi = inducedVelocity(out[i], rho, P.propRadius);
        const f = inflowFactor(-local[2], vh, vi);
        this.vrs = Math.max(this.vrs, f.vrs);
        // Flutter in the vortex ring: a random thrust change of ~15 %, rotor by rotor, at ~20 Hz.
        this.flutter[i] += -af * this.flutter[i] + Math.sqrt(2 * af) * 0.15 * f.vrs * this.rand.gauss();
        out[i] *= Math.max(0.3, f.factor + this.flutter[i]);
      } else if (R.shear > 0) {
        // Without the inflow model the gust still changes the blades' angle of attack.
        out[i] *= 1 - this.shearW[i] * 0.08;
      }
      // Rotor drag (H-force): against the edgewise flow, proportional to rotor speed.
      const h: V3 = [-R.rotorDrag * s.omega[i] * local[0], -R.rotorDrag * s.omega[i] * local[1], 0];
      // Imbalance: a force turning with the rotor in the disc plane, growing with speed squared.
      this.phase[i] += s.omega[i] * dt;
      const u = s.omega[i] / P.omegaMax, F = R.imbalance * u * u;
      const shake: V3 = [F * Math.cos(this.phase[i]), F * Math.sin(this.phase[i]), 0];
      this.shake = add(this.shake, shake);
      const inPlane = add(h, shake);
      force = add(force, inPlane);
      torque = add(torque, cross(r, inPlane));
    }
    // The thrusts act at the motors, but about a centre of mass that is not at their centre.
    torque = add(torque, cross([-b.cg[0], -b.cg[1], 0], [0, 0, out[0] + out[1] + out[2] + out[3]]));
    return { T: out, force, torque };
  }
}

/** The IMU as the flight controller reads it: rates and specific force with noise, bias and the
 *  vibration averaged over the loop step (an 8 kHz gyro decimated by its low-pass). */
export class Imu {
  gyroBias: V3;
  constructor(public R: Realism, private rand: Rng, temperatureC: number) {
    const k = 1 + Math.abs(temperatureC - 25) / 20; // MEMS bias grows away from calibration
    // What is left after the gyro calibration at arming: a fraction of the raw bias.
    this.gyroBias = [0, 1, 2].map(() => this.rand.gauss() * 0.003 * k) as V3;
  }
  read(s: QuadState, aero: Aero | null, mass: number, inertia: V3, dt: number): { w: V3; acc: V3 } {
    const R = this.R, n = () => this.rand.gauss();
    const walk = R.gyroBiasWalk * Math.sqrt(dt);
    this.gyroBias = this.gyroBias.map((b) => b + walk * n()) as V3;
    // Vibration: the shake force accelerates the frame and rocks it about the centre of mass.
    let accVib: V3 = [0, 0, 0], wVib: V3 = [0, 0, 0];
    if (aero && R.imbalance > 0) {
      // Averaging a sinusoid at the rotor frequency over one step attenuates it by sinc(ω dt / 2).
      const meanOmega = s.omega.reduce((a, b) => a + b, 0) / 4;
      const x = (meanOmega * dt) / 2, att = Math.abs(Math.sin(x) / Math.max(x, 1e-6));
      accVib = scale(aero.shake, (att * 6) / mass); // the stack's soft mount still passes some
      wVib = scale([aero.shake[1], -aero.shake[0], 0], (att * R.rotorHeight * 40) / Math.max(inertia[0], 1e-6) * dt);
    }
    return {
      w: add(add(add(s.w, this.gyroBias), wVib), [R.gyroNoise * n(), R.gyroNoise * n(), R.gyroNoise * n()]),
      acc: add(add(s.accBody, accVib), [R.accNoise * n(), R.accNoise * n(), R.accNoise * n()]),
    };
  }
}

/** Mahony's complementary filter: integrates the gyro, pulls toward the accelerometer's gravity
 *  and estimates the gyro bias. Yaw has no magnetometer here; the companion's visual odometry
 *  gives a heading at a low gain. */
export class Mahony {
  q: [number, number, number, number];
  bias: V3 = [0, 0, 0];
  constructor(q: [number, number, number, number], public kp = 1.2, public ki = 0.08) {
    this.q = [...q];
  }
  update(w: V3, acc: V3, headingRef: number | null, dt: number): void {
    const [q0, q1, q2, q3] = this.q;
    // Gravity direction the estimate expects in body axes (third row of R).
    const v: V3 = [2 * (q1 * q3 - q0 * q2), 2 * (q0 * q1 + q2 * q3), q0 * q0 - q1 * q1 - q2 * q2 + q3 * q3];
    const an = Math.hypot(acc[0], acc[1], acc[2]);
    let e: V3 = [0, 0, 0];
    // Trust the accelerometer only near 1 g (a hard manoeuvre is not gravity).
    if (an > 6 && an < 14) e = cross(scale(acc, 1 / an), v);
    if (headingRef !== null) {
      const yaw = Math.atan2(2 * (q0 * q3 + q1 * q2), 1 - 2 * (q2 * q2 + q3 * q3));
      const d = Math.atan2(Math.sin(headingRef - yaw), Math.cos(headingRef - yaw));
      e = add(e, scale(v, d * 0.5)); // about the world vertical, seen in body axes
    }
    this.bias = sub(this.bias, scale(e, this.ki * dt));
    const c = add(sub(w, this.bias), scale(e, this.kp));
    const dq = [
      -q1 * c[0] - q2 * c[1] - q3 * c[2],
      q0 * c[0] + q2 * c[2] - q3 * c[1],
      q0 * c[1] - q1 * c[2] + q3 * c[0],
      q0 * c[2] + q1 * c[1] - q2 * c[0],
    ];
    const q = this.q.map((x, i) => x + 0.5 * dq[i] * dt);
    const l = Math.hypot(...q);
    this.q = q.map((x) => x / l) as Mahony["q"];
  }
}

/** A blow from outside: `impulse` (N·s, world) at `at` (m from the centre of mass, body axes). */
export function kick(s: QuadState, P: QuadParams, Rm: M3, impulse: V3, at: V3 = [0, 0, 0]): void {
  s.v = add(s.v, scale(impulse, 1 / P.mass));
  const L = cross(at, mtv(Rm, impulse));
  s.w = [s.w[0] + L[0] / P.inertia[0], s.w[1] + L[1] / P.inertia[1], s.w[2] + L[2] / P.inertia[2]];
}
