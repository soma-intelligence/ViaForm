// The weather and the air: what changes how the drone flies and what it senses.
//   - Air density from temperature, pressure (altitude) and humidity: thrust and drag scale with it.
//   - Wind (physics.ts Wind): mean, turbulence, gusts.
//   - Rain: water on the blades costs thrust, falling drops push down on the rotor discs, and the
//     time-of-flight sensors see drops as false short returns.
//   - Snow: flakes stick to the frame and add mass, and also make false returns.
//   - Fog and sunlight: infrared ranging loses range (scattering, ambient photons).
//   - Icing: below about 2 °C in saturated air, ice builds on the leading edges and thrust falls.
//   - Cold: the LiPo's internal resistance rises, so the voltage sags more under load.
// Figures are first-order engineering models, not CFD; each is written next to its source idea.

import type { Rng, V3 } from "./math";
import type { WindSpec } from "./physics";

export type Weather = {
  name: string;
  temperatureC: number;
  altitudeM: number;
  humidity: number; // 0..1
  rainMmH: number;
  snowMmH: number; // water equivalent
  fogVisibilityM: number; // Infinity: clear
  sun: number; // 0 night/indoor .. 1 full sun on the sensors
  wind: WindSpec;
};

const W = (mean: V3, turbulence: number, gustEvery: number, gustPeak: number): WindSpec => ({ mean, turbulence, lengthScale: 12, gustEvery, gustPeak });

export const WEATHERS: Weather[] = [
  { name: "Indoor, still air", temperatureC: 21, altitudeM: 50, humidity: 0.45, rainMmH: 0, snowMmH: 0, fogVisibilityM: Infinity, sun: 0, wind: W([0, 0, 0], 0, 0, 0) },
  { name: "Breezy afternoon", temperatureC: 24, altitudeM: 50, humidity: 0.5, rainMmH: 0, snowMmH: 0, fogVisibilityM: Infinity, sun: 0.6, wind: W([3, 1, 0], 0.8, 6, 3) },
  { name: "Gale with gusts", temperatureC: 14, altitudeM: 50, humidity: 0.7, rainMmH: 0, snowMmH: 0, fogVisibilityM: Infinity, sun: 0.2, wind: W([7, -2, 0], 1.8, 3, 6) },
  { name: "Rain storm", temperatureC: 12, altitudeM: 50, humidity: 0.98, rainMmH: 25, snowMmH: 0, fogVisibilityM: 400, sun: 0, wind: W([5, 3, 0], 1.5, 4, 5) },
  { name: "Snow, −8 °C", temperatureC: -8, altitudeM: 400, humidity: 0.9, rainMmH: 0, snowMmH: 3, fogVisibilityM: 300, sun: 0.1, wind: W([3, -1, 0], 1, 6, 3) },
  { name: "Freezing fog (icing)", temperatureC: -1, altitudeM: 200, humidity: 1, rainMmH: 0, snowMmH: 0, fogVisibilityM: 40, sun: 0, wind: W([1.5, 0, 0], 0.4, 0, 0) },
  { name: "Hot and high, 2 400 m", temperatureC: 34, altitudeM: 2400, humidity: 0.2, rainMmH: 0, snowMmH: 0, fogVisibilityM: Infinity, sun: 1, wind: W([4, 2, 0], 1.2, 5, 4) },
];

/** Air density (kg/m³): ISA pressure at altitude, ideal gas with the water vapour's share. */
export function airDensity(w: Pick<Weather, "temperatureC" | "altitudeM" | "humidity">): number {
  const T = w.temperatureC + 273.15;
  const p = 101325 * Math.pow(1 - 2.25577e-5 * w.altitudeM, 5.25588);
  const es = 610.78 * Math.pow(10, (7.5 * w.temperatureC) / (w.temperatureC + 237.3)); // Tetens, Pa
  const pv = w.humidity * es;
  return (p - pv) / (287.058 * T) + pv / (461.495 * T);
}

/** The slowly changing state of the airframe in this weather (ice, snow load). */
export class Exposure {
  ice = 0; // 0..1 of the thrust loss icing can cause (about 30 % at 1)
  snowKg = 0;
  wetness = 0; // 0..1, water film on the blades
  constructor(public w: Weather) {}

  update(dt: number): void {
    const w = this.w;
    const icing = w.temperatureC < 2 && w.temperatureC > -15 && w.humidity > 0.85 && (w.fogVisibilityM < 1000 || w.rainMmH > 0);
    // Rime builds over minutes in freezing fog; spinning props shed some of it.
    this.ice = Math.min(1, Math.max(0, this.ice + (icing ? dt / 240 : -dt / 60)));
    // Snow settles on the top plate and the pack; a few grams a minute at most, some blows off.
    this.snowKg = Math.min(0.012, Math.max(0, this.snowKg + dt * (w.snowMmH * 4e-6 - this.snowKg * 0.01)));
    this.wetness = Math.min(1, Math.max(0, this.wetness + dt * (w.rainMmH > 0 ? 0.5 : -0.05)));
  }

  /** Fraction of clean-air thrust the props make: water film and ice on the blades. */
  thrustFactor(): number {
    return (1 - 0.04 * this.wetness * Math.min(1, this.w.rainMmH / 20)) * (1 - 0.3 * this.ice);
  }

  /** Downward force (N) of rain falling through the four rotor discs (momentum of the drops at
   *  their ~7 m/s terminal speed); small, but it is there. */
  rainForce(propRadius: number): number {
    const massFlux = (this.w.rainMmH / 3600) * 1e-3 * 1000; // kg/m²/s
    return massFlux * 7 * 4 * Math.PI * propRadius * propRadius;
  }
}

/** Time-of-flight ranging in this weather: the usable range and how often a drop or a flake
 *  returns a false short reading per zone read. */
export function tofConditions(w: Weather, nominal: number): { range: number; falseRate: number } {
  // VL53L1X: ~4 m in the dark, ~1.3 m in full sun (ST's ambient figures); fog attenuates both ways.
  const sunRange = nominal - (nominal - 1.3) * w.sun;
  const fogRange = Number.isFinite(w.fogVisibilityM) ? Math.min(sunRange, w.fogVisibilityM / 12) : sunRange;
  const falseRate = Math.min(0.2, w.rainMmH * 0.002 + w.snowMmH * 0.02);
  return { range: Math.max(0.6, fogRange), falseRate };
}

/** Applies false returns to a zone reading. */
export function precipitationReturn(d: number, range: number, falseRate: number, rand: Rng): number {
  return rand.next() < falseRate ? Math.min(d, rand.range(0.05, 0.6 * range)) : d;
}

// MARK: Battery

/** A 3S LiPo: open-circuit voltage from the state of charge, internal resistance rising in the
 *  cold (roughly doubling from 25 °C to 0 °C), capacity lower in the cold. */
export class Battery {
  soc = 1; // state of charge 0..1
  voltage = 12.6;
  current = 0;
  constructor(public capacityAh = 0.65, public cells = 3, public temperatureC = 25, public resistance25 = 0.012 /* Ω per cell */) {}

  ocvCell(): number {
    const s = this.soc;
    // A typical LiPo discharge curve: steep at both ends, flat in the middle.
    return 3.3 + 0.9 * s - 0.35 * Math.exp(-12 * s) + 0.1 * Math.exp(-8 * (1 - s));
  }
  resistanceCell(): number {
    return this.resistance25 * Math.exp(Math.max(0, 25 - this.temperatureC) * 0.03);
  }
  usableCapacity(): number {
    return this.capacityAh * (this.temperatureC >= 15 ? 1 : Math.max(0.6, 1 - (15 - this.temperatureC) * 0.012));
  }
  /** Draws `current` amps for dt seconds; returns the loaded pack voltage. */
  draw(current: number, dt: number): number {
    this.current = current;
    this.soc = Math.max(0, this.soc - (current * dt) / 3600 / this.usableCapacity());
    // The pack warms itself under load (I²R), which helps in the cold.
    this.temperatureC += ((current * current * this.resistanceCell() * this.cells) / 25) * dt * 0.02;
    this.voltage = this.cells * (this.ocvCell() - current * this.resistanceCell());
    return this.voltage;
  }
}

/** Current (A) of one motor making `thrustN`: fits the F1404 table (≈ 9 A at its ≈ 1.8 N 3S
 *  maximum, scaled from 17.5 A at 3.4 N on 4S) with the T^1.5 law of momentum theory. */
export const motorCurrent = (thrustN: number, maxThrustN: number) => 0.3 + 9 * Math.pow(Math.max(0, thrustN) / maxThrustN, 1.5);
