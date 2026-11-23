// One flight: the drone, the weather, the course, the sensors, the companion computer's planner
// and the flight controller, stepped together at the rates the real hardware runs at:
// physics and the rate loop at 500 Hz, position and velocity at 100 Hz, the distance sensors at
// 30 Hz and the planner at 20 Hz. The app draws a Flight frame by frame; tests and training run
// whole episodes with runEpisode.

import { add, col, dot, norm, qFromEuler, qToM3, rng, scale, sub, type Rng, type V3 } from "./math";
import { Cascade, DEFAULT_GAINS, headingOf, type Estimate, type Gains, type Limits, type RateLoop, type Setpoint } from "./control";
import { Aero, Imu, kick, Mahony, makeBuild, REALISTIC, type Realism } from "./realism";
import { G, newState, step, thrusts, Wind, type Env, type QuadParams, type QuadState } from "./physics";
import { Planner, DEFAULT_PLANNER, type PlanOut } from "./planner";
import { Policy, policyInput } from "./policy";
import { MOTOR_THRUST_3S_N } from "./parts";
import { TRAINED_GAINS, TRAINED_POLICY } from "./trained";
import { STABLE_INDI, STABLE_PID } from "./stable";
import { airDensity, Battery, Exposure, motorCurrent, precipitationReturn, tofConditions, type Weather, WEATHERS } from "./weather";
import { clearance, readTof, tofArray, type Course, type TofHit } from "./world";

export const DT = 0.002;

/** The 3-inch quad from its parts: mass and inertia from the CAD when given. */
export function quad3(mass = 0.175, inertia: V3 = [1.9e-4, 2.1e-4, 3.5e-4], arm = 0.0602): QuadParams {
  const omegaMax = 4000; // rad/s: 4600 KV on a loaded 3S pack, ~38 000 rpm
  return {
    mass, inertia, arm,
    kT: MOTOR_THRUST_3S_N / (omegaMax * omegaMax),
    kQ: (MOTOR_THRUST_3S_N / (omegaMax * omegaMax)) * 0.009,
    omegaMax, omegaIdle: 0.12 * omegaMax, motorTau: 0.025,
    dragLinear: [0.045, 0.045, 0.06], dragQuad: [0.006, 0.006, 0.012],
    propRadius: 0.0381, bodyRadius: 0.1,
  };
}

export type Brain = { gains: Gains; policy: Policy | null; rateLoop?: RateLoop; limits?: Partial<Limits> };
export const PID_ONLY = (gains: Gains = DEFAULT_GAINS): Brain => ({ gains: { ...gains }, policy: null });
/** What scripts/train-drone.mjs learned: tuned gains, and with `nn` the neural residual on top. */
export const TRAINED = (nn = true): Brain => ({ gains: { ...TRAINED_GAINS }, policy: nn ? new Policy(Float64Array.from(TRAINED_POLICY)) : null });
/** What scripts/train-stabilize.mjs tuned on the realistic plant, with either rate loop. */
export const STABLE = (rateLoop: RateLoop = "pid"): Brain => ({ gains: { ...(rateLoop === "indi" ? STABLE_INDI : STABLE_PID) }, policy: null, rateLoop, limits: { rateIntMax: 50 } });

export type Mission =
  | { kind: "hover"; at: V3 }
  | { kind: "waypoints"; course: Course }
  /** Flown by a person (the game): `Flight.pilot` holds the sticks; the course is for collisions. */
  | { kind: "manual"; course: Course }
  /** Velocity steps (training): each entry holds from its time until the next. */
  | { kind: "track"; at: V3; steps: { t: number; v: V3 }[] }
  /** Hold a point while things are done to the drone (the stabilization bench). */
  | { kind: "stabilize"; at: V3; events: Disturbance[] };

/** Something done to the drone at time t. */
export type Disturbance =
  /** A blow: impulse (N·s, world) at a point (m from the centre of mass, body axes). */
  | { t: number; kind: "kick"; impulse: V3; at: V3 }
  /** A sharp-edged gust on top of the weather, for `length` seconds. */
  | { t: number; kind: "gust"; wind: V3; length: number }
  /** A damaged prop: that motor makes `health` of its thrust from now on. */
  | { t: number; kind: "prop"; motor: number; health: number }
  /** A payload picked up (kg > 0) or dropped (kg < 0), off-centre by `at` (m, body). */
  | { t: number; kind: "payload"; kg: number; at: V3 }
  /** Thrown or knocked into a tumble: body rates (rad/s) all at once. */
  | { t: number; kind: "tumble"; rates: V3 };

/** How the drone came back from one disturbance. */
export type Recovery = { kind: Disturbance["kind"]; t: number; maxDeviation: number; maxTilt: number; recoveredAfter: number | null };

export type Scenario = {
  weather: Weather; mission: Mission; duration: number; seed: number; tofRange?: number; massScale?: number; thrustScale?: number;
  /** The plant and sensor effects of realism.ts; without it, the rigid body and simple noise. */
  realism?: Realism;
};

export type Frame = {
  t: number; p: V3; q: [number, number, number, number]; v: V3; omega: number[]; wind: V3;
  target: V3; hits: TofHit[]; voltage: number; soc: number; residual: V3; planIndex: number;
};

/** Sticks, each -1..1: forward, left, up, and yaw rate to the left. */
export type PilotInput = { x: number; y: number; z: number; yaw: number };
/** "position": the drone holds its place when the sticks are centred and flies the velocity the
 *  sticks ask for. "angle": the sticks tilt it (up to 35°) and it keeps going, as a racing quad in
 *  angle mode; only height is held. */
export type PilotMode = "position" | "angle";
const PILOT_SPEED = 5, PILOT_CLIMB = 2.5, PILOT_YAW = 2.4, PILOT_TILT = (35 * Math.PI) / 180;

export class Flight {
  s: QuadState;
  ctl: Cascade;
  wind: Wind;
  battery: Battery;
  exposure: Exposure;
  planner: Planner | null = null;
  plan: PlanOut | null = null;
  hits: TofHit[] = [];
  rand: Rng;
  rho: number;
  tof: ReturnType<typeof tofConditions>;
  sensors = tofArray();
  sp: Setpoint;
  acc: V3 = [0, 0, 0];
  residual: V3 = [0, 0, 0];
  windNow: V3 = [0, 0, 0];
  gyroBias: V3;
  collided = false;
  minClearance = Infinity;
  energyJ = 0;
  trackError = 0;
  errSq = 0;
  errMax = 0;
  errN = 0;
  private k = 0;
  P: QuadParams;
  /** The sticks, for a manual mission. */
  pilot: PilotInput = { x: 0, y: 0, z: 0, yaw: 0 };
  pilotMode: PilotMode = "position";
  private pilotYaw = 0;
  private hold: V3 | null = null;
  /** realism.ts state, when the scenario asks for it. */
  realism: Realism | null;
  aero: Aero | null = null;
  imu: Imu | null = null;
  ahrs: Mahony | null = null;
  private wLp: V3 = [0, 0, 0];
  private pErr: V3 = [0, 0, 0];
  private pDrift: V3 = [0, 0, 0];
  private vDrift: V3 = [0, 0, 0];
  private vErr: V3 = [0, 0, 0];
  private escQueue: number[][] = [];
  /** Disturbances still to come, and gusts and payload now in effect. */
  private pending: Disturbance[] = [];
  private gusts: { until: number; wind: V3 }[] = [];
  payloadKg = 0;
  private payloadAt: V3 = [0, 0, 0];
  recoveries: Recovery[] = [];
  private calmSince = -1;
  private zDesLp: V3 = [0, 0, 1];
  attErrSq = 0;
  attErrN = 0;
  /** Last disturbance, for the app to draw (time and world impulse or wind). */
  lastHit: { t: number; kind: Disturbance["kind"]; vec: V3 } | null = null;

  constructor(base: QuadParams, public brain: Brain, public sc: Scenario) {
    this.rand = rng(sc.seed);
    // Each flight's drone differs a little from the nominal one, as real builds do.
    this.P = { ...base, mass: base.mass * (sc.massScale ?? 1), kT: base.kT * (sc.thrustScale ?? 1) };
    const start: V3 = sc.mission.kind === "waypoints" || sc.mission.kind === "manual" ? add(sc.mission.course.start, [0, 0, 0]) : sc.mission.at;
    this.s = newState(start, qFromEuler(0, 0, 0));
    if (sc.mission.kind !== "waypoints" && sc.mission.kind !== "manual") {
      // Start hovering: motors at hover speed, so the test measures holding, not taking off.
      const hover = Math.sqrt((this.P.mass * 9.81) / 4 / this.P.kT);
      this.s.omega = [hover, hover, hover, hover];
    }
    this.ctl = new Cascade(this.P, { ...brain.gains });
    this.ctl.rateLoop = brain.rateLoop ?? "pid";
    Object.assign(this.ctl.lim, brain.limits ?? {});
    this.ctl.P = { ...this.P }; // the controller knows the nominal parameters only
    this.ctl.P.mass = base.mass;
    this.ctl.P.kT = base.kT;
    this.wind = new Wind(sc.weather.wind, this.rand);
    this.battery = new Battery(0.65, 3, sc.weather.temperatureC);
    this.exposure = new Exposure(sc.weather);
    this.rho = airDensity(sc.weather);
    this.tof = tofConditions(sc.weather, sc.tofRange ?? 4);
    this.sensors = tofArray(this.tof.range);
    this.gyroBias = [0, 1, 2].map(() => this.rand.gauss() * 0.01 * (1 + Math.abs(sc.weather.temperatureC - 25) / 20)) as V3;
    if (sc.mission.kind === "waypoints") {
      const course = sc.mission.course;
      this.planner = new Planner(course.waypoints, { ...DEFAULT_PLANNER, sensorRange: this.tof.range }, course.bounds);
      // The drone gets the course plan (the gates); the rest only its sensors find.
      course.obstacles.forEach((o, i) => !course.hidden.includes(i) && this.planner!.map.know(o));
    }
    this.sp = { mode: "position", p: start, yaw: 0 };
    this.realism = sc.realism ?? (sc.mission.kind === "stabilize" ? REALISTIC : null);
    if (this.realism) {
      // Its own random stream, so the rest of the flight draws the same numbers as without.
      const r2 = rng(sc.seed * 7919 + 13);
      this.aero = new Aero(this.realism, makeBuild(this.realism, r2), r2);
      this.imu = new Imu(this.realism, r2, sc.weather.temperatureC);
      this.ahrs = new Mahony(this.s.q);
    }
    if (sc.mission.kind === "stabilize") this.pending = [...sc.mission.events].sort((a, b) => a.t - b.t);
  }

  /** Does `d` to the drone now (the app's kick button; scheduled ones come through tick). */
  disturb(d: Disturbance): void {
    const s = this.s, R = qToM3(s.q);
    let vec: V3 = [0, 0, 0];
    if (d.kind === "kick") {
      kick(s, this.P, R, d.impulse, d.at);
      vec = d.impulse;
    } else if (d.kind === "gust") {
      this.gusts.push({ until: s.t + d.length, wind: d.wind });
      vec = d.wind;
    } else if (d.kind === "prop") {
      if (this.aero) this.aero.build.kT[d.motor] *= d.health;
    } else if (d.kind === "payload") {
      const before = this.payloadKg;
      this.payloadKg = Math.max(0, before + d.kg);
      // The centre of mass moves toward the payload; the aero model keeps the offset.
      if (this.aero) {
        const m = this.P.mass + this.payloadKg, dm = this.payloadKg - before;
        this.aero.build.cg = add(this.aero.build.cg, scale(d.at, dm / m));
      }
      this.payloadAt = d.at;
      vec = [0, 0, -d.kg * G];
    } else if (d.kind === "tumble") {
      s.w = add(s.w, d.rates);
      vec = d.rates;
    }
    this.lastHit = { t: s.t, kind: d.kind, vec };
    this.recoveries.push({ kind: d.kind, t: s.t, maxDeviation: 0, maxTilt: 0, recoveredAfter: null });
    this.calmSince = -1;
  }

  get course(): Course | null {
    return this.sc.mission.kind === "waypoints" || this.sc.mission.kind === "manual" ? this.sc.mission.course : null;
  }

  estimate(): Estimate {
    const r = this.rand, s = this.s;
    const n = (x: number) => x * r.gauss();
    if (this.imu && this.ahrs) {
      // The flight controller's view: its IMU, its attitude filter, the companion's position.
      const m = this.imu.read(s, this.aero, this.P.mass + this.payloadKg, this.P.inertia, DT);
      const heading = headingOf(qToM3(s.q)) + n(0.02);
      this.ahrs.update(m.w, m.acc, heading, DT);
      // Gyro low-pass (PT1 at ~80 Hz), as every flight controller runs before its loops.
      this.wLp = add(this.wLp, scale(sub(m.w, this.wLp), 0.5));
      // The companion's position and velocity come out of a filter (visual-inertial odometry,
      // integrating the IMU between camera frames): their errors wander slowly and smoothly
      // rather than jump every sample. A random walk pulled back (0.3 s), then smoothed (0.08 s).
      const a = DT / 0.3, k = Math.sqrt(2 * a), b = DT / 0.08;
      this.pDrift = this.pDrift.map((x, i) => x - a * x + k * (i === 2 ? 0.015 : 0.02) * r.gauss()) as V3;
      this.vDrift = this.vDrift.map((x, i) => x - a * x + k * (i === 2 ? 0.03 : 0.04) * r.gauss()) as V3;
      this.pErr = add(this.pErr, scale(sub(this.pDrift, this.pErr), b));
      this.vErr = add(this.vErr, scale(sub(this.vDrift, this.vErr), b));
      return {
        p: add(add(s.p, this.pErr), [n(0.001), n(0.001), n(0.001)]),
        v: add(add(s.v, this.vErr), [n(0.002), n(0.002), n(0.002)]),
        R: qToM3(this.ahrs.q),
        w: this.wLp,
        accBody: m.acc,
      };
    }
    return {
      p: add(s.p, [n(0.02), n(0.02), n(0.015)]),
      v: add(s.v, [n(0.04), n(0.04), n(0.03)]),
      R: qToM3(s.q),
      w: add(add(s.w, this.gyroBias), [n(0.03), n(0.03), n(0.03)]),
      accBody: add(s.accBody, [n(0.3), n(0.3), n(0.3)]),
    };
  }

  /** Advances one physics step (2 ms). */
  tick(): void {
    const s = this.s, P = this.P;
    if (s.crashed || this.collided) return;
    const k = this.k++;
    while (this.pending.length && this.pending[0].t <= s.t) this.disturb(this.pending.shift()!);
    const e = this.estimate();

    // 30 Hz ranging, 20 Hz planning.
    if (this.planner && k % 17 === 0) {
      this.hits = readTof(this.sensors, this.course!.obstacles, s.p, s.q, this.rand).map((h) => {
        const d = precipitationReturn(h.d, this.tof.range, this.tof.falseRate, this.rand);
        return d === h.d ? h : { ...h, d, hit: true, point: add(s.p, scale(h.dir, d)) };
      });
      this.planner.observe(s.p, this.hits);
    }
    if (this.planner && k % 25 === 0) {
      // Take off first, then follow the plan.
      if (s.t < 1.2) this.sp = { mode: "position", p: this.planner.waypoints[0], yaw: 0 };
      else {
        this.plan = this.planner.plan(e.p, e.v, this.trackError);
        const landing = this.plan.done || (this.plan.index === this.planner.waypoints.length - 1 && this.plan.target[2] < 0.05);
        this.sp = landing ? { mode: "position", p: this.plan.target, yaw: this.plan.yaw } : { mode: "velocity", v: this.plan.v, yaw: this.plan.yaw };
      }
    }

    if (this.sc.mission.kind === "track" && k % 5 === 0) {
      const steps = this.sc.mission.steps;
      let cur = steps[0];
      for (const st of steps) if (st.t <= s.t) cur = st;
      this.sp = { mode: "velocity", v: cur.v, yaw: 0 };
    }

    let angleAcc: V3 | null = null;
    if (this.sc.mission.kind === "manual" && k % 5 === 0) {
      const u = this.pilot, c = Math.cos(this.pilotYaw), sn = Math.sin(this.pilotYaw);
      const dz = (x: number) => (Math.abs(x) < 0.06 ? 0 : x);
      this.pilotYaw += dz(u.yaw) * PILOT_YAW * DT * 5;
      const vz = dz(u.z) * PILOT_CLIMB;
      if (this.pilotMode === "angle") {
        // Height held by the velocity loop; the tilt straight from the sticks.
        this.sp = { mode: "velocity", v: [e.v[0], e.v[1], vz], yaw: this.pilotYaw };
        const ax = Math.tan(PILOT_TILT) * G * dz(u.x), ay = Math.tan(PILOT_TILT) * G * dz(u.y);
        angleAcc = [c * ax - sn * ay, sn * ax + c * ay, 0];
      } else {
        const fwd = dz(u.x) * PILOT_SPEED, left = dz(u.y) * PILOT_SPEED;
        // Sticks centred: hold the spot where the drone came to rest.
        const still = !fwd && !left;
        if (!still) this.hold = null;
        else if (!this.hold && Math.hypot(e.v[0], e.v[1]) < 0.4) this.hold = [e.p[0], e.p[1], e.p[2]];
        const v: V3 = [c * fwd - sn * left, sn * fwd + c * left, vz];
        this.sp = this.hold && !vz ? { mode: "position", p: this.hold, yaw: this.pilotYaw } : { mode: "velocity", v, yaw: this.pilotYaw };
        if (this.hold && vz) this.hold = null;
      }
    }

    // 100 Hz outer loop, with the learned correction.
    if (k % 5 === 0) {
      if (this.sp.mode === "velocity") this.trackError += (norm(sub(this.sp.v, e.v)) - this.trackError) * 0.01;
      this.acc = this.ctl.outer(e, this.sp, DT * 5);
      if (this.brain.policy) {
        const zb = col(e.R, 2);
        const thrustAcc = scale(zb, this.ctl.thrustCmd / this.ctl.P.mass);
        const measured = col(e.R, 0).map((_, i) => e.R[i * 3] * e.accBody[0] + e.R[i * 3 + 1] * e.accBody[1] + e.R[i * 3 + 2] * e.accBody[2]) as V3;
        const force = sub(measured, thrustAcc);
        const vSp = this.sp.mode === "velocity" ? this.sp.v : scale(sub(this.sp.p, e.p), this.ctl.g.posP);
        const heading = headingOf(e.R);
        const c = Math.cos(heading), sn = Math.sin(heading);
        this.residual = this.brain.policy.act(policyInput({
          velErr: sub(vSp, e.v), v: e.v, force, tilt: [c * zb[0] + sn * zb[1], -sn * zb[0] + c * zb[1]], w: e.w, velInt: this.ctl.velInt, heading,
        }));
        // Back from the heading frame to the world.
        const r = this.residual;
        this.acc = add(this.acc, [c * r[0] - sn * r[1], sn * r[0] + c * r[1], r[2]]);
      }
      if (angleAcc) this.acc = [angleAcc[0], angleAcc[1], this.acc[2]];
    }
    // The ESCs report each motor's speed (bidirectional DShot), with a little noise.
    const rpm = s.omega.map((o) => o * (1 + 0.004 * this.rand.gauss()));
    let cmd = this.ctl.inner(e, this.acc, this.sp.yaw, DT, rpm);
    if (this.realism?.escDelay) {
      // DShot frame and the ESC's own loop: the motors act on a command a step or two old.
      this.escQueue.push(cmd);
      cmd = this.escQueue.length > this.realism.escDelay ? this.escQueue.shift()! : this.escQueue[0];
    }

    // Weather, battery and the step itself.
    this.exposure.update(DT);
    this.windNow = this.wind.at(s.t, DT, norm(s.v));
    this.gusts = this.gusts.filter((g) => g.until > s.t);
    for (const g of this.gusts) this.windNow = add(this.windNow, g.wind);
    const T = thrusts(P, s);
    const amps = T.reduce((a, t) => a + motorCurrent(t, MOTOR_THRUST_3S_N), 0) + 0.6; // + FC, VTX-free stack, ESP32, sensors
    const volts = this.battery.draw(amps, DT);
    this.energyJ += volts * amps * DT;
    const env: Env = {
      rho: this.rho,
      thrustFactor: this.exposure.thrustFactor(),
      extraMass: this.exposure.snowKg + this.payloadKg,
      downForce: this.exposure.rainForce(P.propRadius),
      omegaScale: Math.min(1, volts / 11.4),
      turbulence: this.sc.weather.wind.turbulence,
    };
    step(P, s, cmd, this.windNow, DT, env, this.aero);

    if (this.course && k % 5 === 0) {
      const c = clearance(this.course.obstacles, s.p);
      this.minClearance = Math.min(this.minClearance, c);
      if (c < P.bodyRadius) this.collided = true;
    }
    const target = this.sc.mission.kind === "hover" || this.sc.mission.kind === "stabilize" ? this.sc.mission.at : null;
    if (k % 5 === 0) this.measureAttitude(target);
    if (this.sc.mission.kind === "track" && k % 5 === 0 && this.sp.mode === "velocity") {
      const err = norm(sub(s.v, this.sp.v));
      this.errSq += err * err + 0.01 * (s.w[0] ** 2 + s.w[1] ** 2 + s.w[2] ** 2);
      this.errN++;
      this.errMax = Math.max(this.errMax, err);
    }
    if (target && s.t > 1) {
      const err = norm(sub(s.p, target));
      this.errSq += err * err;
      this.errN++;
      this.errMax = Math.max(this.errMax, err);
    }
  }

  /** Attitude error against what the controller asked for, and each disturbance's recovery:
   *  back within 0.25 m of the point, below 1.5 rad/s and 10° of tilt error, for 0.5 s. */
  private measureAttitude(target: V3 | null): void {
    const s = this.s, R = qToM3(s.q);
    // Against the command smoothed to what a drone can follow (~6 Hz): the raw one carries the
    // position estimate's noise at 100 Hz.
    this.zDesLp = add(this.zDesLp, scale(sub(this.ctl.zDes, this.zDesLp), 0.25));
    const err = Math.acos(Math.max(-1, Math.min(1, dot(col(R, 2), this.zDesLp) / norm(this.zDesLp))));
    if (s.t > 0.5) {
      this.attErrSq += err * err;
      this.attErrN++;
    }
    const rec = this.recoveries[this.recoveries.length - 1];
    if (!rec || rec.recoveredAfter !== null) return;
    const dev = target ? norm(sub(s.p, target)) : 0;
    const tilt = Math.acos(Math.max(-1, Math.min(1, R[8])));
    rec.maxDeviation = Math.max(rec.maxDeviation, dev);
    rec.maxTilt = Math.max(rec.maxTilt, tilt);
    const calm = dev < 0.25 && norm(s.w) < 1.5 && err < 0.17;
    if (!calm) this.calmSince = -1;
    else if (this.calmSince < 0) this.calmSince = s.t;
    else if (s.t - this.calmSince >= 0.5) rec.recoveredAfter = this.calmSince - rec.t;
  }

  frame(): Frame {
    const s = this.s;
    return {
      t: s.t, p: [...s.p] as V3, q: [...s.q] as Frame["q"], v: [...s.v] as V3, omega: [...s.omega], wind: this.windNow,
      target: this.plan?.target ?? (this.sp.mode === "position" ? this.sp.p : s.p), hits: this.hits, voltage: this.battery.voltage,
      soc: this.battery.soc, residual: this.residual, planIndex: this.plan?.index ?? 0,
    };
  }

  get finished(): boolean {
    return this.s.crashed || this.collided || this.s.t >= this.sc.duration || (!!this.plan?.done && norm(this.s.v) < 0.2 && this.s.p[2] < 0.1);
  }
}

export type Result = {
  crashed: boolean;
  collided: boolean;
  completed: boolean;
  time: number;
  rmsError: number;
  maxError: number;
  minClearance: number;
  energyWh: number;
  waypointsReached: number;
  /** RMS angle (rad) between the thrust axis and the one the controller asked for. */
  attitudeRms: number;
  recoveries: Recovery[];
  trace?: Frame[];
};

export function runEpisode(P: QuadParams, brain: Brain, sc: Scenario, record = 0): Result {
  const f = new Flight(P, brain, sc);
  const trace: Frame[] = [];
  let n = 0;
  while (!f.finished) {
    f.tick();
    if (record && n++ % record === 0) trace.push(f.frame());
  }
  if (record) trace.push(f.frame());
  return {
    crashed: f.s.crashed,
    collided: f.collided,
    completed: !!f.plan?.done,
    time: f.s.t,
    rmsError: f.errN ? Math.sqrt(f.errSq / f.errN) : 0,
    maxError: f.errMax,
    minClearance: f.minClearance,
    energyWh: f.energyJ / 3600,
    waypointsReached: f.plan?.index ?? 0,
    attitudeRms: f.attErrN ? Math.sqrt(f.attErrSq / f.attErrN) : 0,
    recoveries: f.recoveries,
    trace: record ? trace : undefined,
  };
}

export { WEATHERS };
