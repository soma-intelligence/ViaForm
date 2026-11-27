//! The weather and the air: what changes how the drone flies and what it senses.
//!   - Air density from temperature, pressure (altitude) and humidity: thrust and drag scale with it.
//!   - Wind (physics.rs Wind): mean, turbulence, gusts.
//!   - Rain: water on the blades costs thrust, falling drops push down on the rotor discs, and the
//!     time-of-flight sensors see drops as false short returns.
//!   - Snow: flakes stick to the frame and add mass, and also make false returns.
//!   - Fog and sunlight: infrared ranging loses range (scattering, ambient photons).
//!   - Icing: below about 2 °C in saturated air, ice builds on the leading edges and thrust falls.
//!   - Cold: the LiPo's internal resistance rises, so the voltage sags more under load.
//! Figures are first-order engineering models, not CFD; each is written next to its source idea.

use serde::{Deserialize, Serialize};

use crate::math::*;
use crate::physics::WindSpec;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Weather {
    pub name: String,
    pub temperature_c: f64,
    pub altitude_m: f64,
    pub humidity: f64, // 0..1
    pub rain_mm_h: f64,
    pub snow_mm_h: f64, // water equivalent
    pub fog_visibility_m: f64, // f64::INFINITY: clear
    pub sun: f64, // 0 night/indoor .. 1 full sun on the sensors
    pub wind: WindSpec,
}

fn w(mean: V3, turbulence: f64, gust_every: f64, gust_peak: f64) -> WindSpec {
    WindSpec { mean, turbulence, length_scale: 12.0, gust_every, gust_peak }
}

#[allow(clippy::too_many_arguments)]
fn preset(name: &str, temperature_c: f64, altitude_m: f64, humidity: f64, rain_mm_h: f64, snow_mm_h: f64, fog_visibility_m: f64, sun: f64, wind: WindSpec) -> Weather {
    Weather { name: name.into(), temperature_c, altitude_m, humidity, rain_mm_h, snow_mm_h, fog_visibility_m, sun, wind }
}

/// The seven presets, calm to a gale, rain, snow, freezing fog and hot and high.
pub fn weathers() -> Vec<Weather> {
    let inf = f64::INFINITY;
    vec![
        preset("Indoor, still air", 21.0, 50.0, 0.45, 0.0, 0.0, inf, 0.0, w([0.0, 0.0, 0.0], 0.0, 0.0, 0.0)),
        preset("Breezy afternoon", 24.0, 50.0, 0.5, 0.0, 0.0, inf, 0.6, w([3.0, 1.0, 0.0], 0.8, 6.0, 3.0)),
        preset("Gale with gusts", 14.0, 50.0, 0.7, 0.0, 0.0, inf, 0.2, w([7.0, -2.0, 0.0], 1.8, 3.0, 6.0)),
        preset("Rain storm", 12.0, 50.0, 0.98, 25.0, 0.0, 400.0, 0.0, w([5.0, 3.0, 0.0], 1.5, 4.0, 5.0)),
        preset("Snow, −8 °C", -8.0, 400.0, 0.9, 0.0, 3.0, 300.0, 0.1, w([3.0, -1.0, 0.0], 1.0, 6.0, 3.0)),
        preset("Freezing fog (icing)", -1.0, 200.0, 1.0, 0.0, 0.0, 40.0, 0.0, w([1.5, 0.0, 0.0], 0.4, 0.0, 0.0)),
        preset("Hot and high, 2 400 m", 34.0, 2400.0, 0.2, 0.0, 0.0, inf, 1.0, w([4.0, 2.0, 0.0], 1.2, 5.0, 4.0)),
    ]
}

/// Air density (kg/m³): ISA pressure at altitude, ideal gas with the water vapour's share.
pub fn air_density(w: &Weather) -> f64 {
    let t = w.temperature_c + 273.15;
    let p = 101325.0 * (1.0 - 2.25577e-5 * w.altitude_m).powf(5.25588);
    let es = 610.78 * 10f64.powf(7.5 * w.temperature_c / (w.temperature_c + 237.3)); // Tetens, Pa
    let pv = w.humidity * es;
    (p - pv) / (287.058 * t) + pv / (461.495 * t)
}

/// The slowly changing state of the airframe in this weather (ice, snow load).
#[derive(Clone, Debug)]
pub struct Exposure {
    pub w: Weather,
    pub ice: f64, // 0..1 of the thrust loss icing can cause (about 30 % at 1)
    pub snow_kg: f64,
    pub wetness: f64, // 0..1, water film on the blades
}

impl Exposure {
    pub fn new(w: Weather) -> Self {
        Exposure { w, ice: 0.0, snow_kg: 0.0, wetness: 0.0 }
    }
    pub fn update(&mut self, dt: f64) {
        let w = &self.w;
        let icing = w.temperature_c < 2.0 && w.temperature_c > -15.0 && w.humidity > 0.85 && (w.fog_visibility_m < 1000.0 || w.rain_mm_h > 0.0);
        // Rime builds over minutes in freezing fog; spinning props shed some of it.
        self.ice = (self.ice + if icing { dt / 240.0 } else { -dt / 60.0 }).max(0.0).min(1.0);
        // Snow settles on the top plate and the pack; a few grams a minute at most, some blows off.
        self.snow_kg = (self.snow_kg + dt * (w.snow_mm_h * 4e-6 - self.snow_kg * 0.01)).max(0.0).min(0.012);
        self.wetness = (self.wetness + dt * if w.rain_mm_h > 0.0 { 0.5 } else { -0.05 }).max(0.0).min(1.0);
    }
    /// Fraction of clean-air thrust the props make: water film and ice on the blades.
    pub fn thrust_factor(&self) -> f64 {
        (1.0 - 0.04 * self.wetness * (self.w.rain_mm_h / 20.0).min(1.0)) * (1.0 - 0.3 * self.ice)
    }
    /// Downward force (N) of rain falling through the four rotor discs (momentum of the drops at
    /// their ~7 m/s terminal speed); small, but it is there.
    pub fn rain_force(&self, prop_radius: f64) -> f64 {
        let mass_flux = (self.w.rain_mm_h / 3600.0) * 1e-3 * 1000.0; // kg/m²/s
        mass_flux * 7.0 * 4.0 * PI * prop_radius * prop_radius
    }
}

/// Time-of-flight ranging in this weather: the usable range and how often a drop or a flake
/// returns a false short reading per zone read. Returns (range, false_rate).
pub fn tof_conditions(w: &Weather, nominal: f64) -> (f64, f64) {
    // VL53L1X: ~4 m in the dark, ~1.3 m in full sun (ST's ambient figures); fog attenuates both ways.
    let sun_range = nominal - (nominal - 1.3) * w.sun;
    let fog_range = if w.fog_visibility_m.is_finite() { sun_range.min(w.fog_visibility_m / 12.0) } else { sun_range };
    let false_rate = (w.rain_mm_h * 0.002 + w.snow_mm_h * 0.02).min(0.2);
    (fog_range.max(0.6), false_rate)
}

/// Applies false returns to a zone reading.
pub fn precipitation_return(d: f64, range: f64, false_rate: f64, rand: &mut Rng) -> f64 {
    if rand.next() < false_rate { d.min(rand.range(0.05, 0.6 * range)) } else { d }
}

// MARK: Battery

/// A 3S LiPo: open-circuit voltage from the state of charge, internal resistance rising in the
/// cold (roughly doubling from 25 °C to 0 °C), capacity lower in the cold.
#[derive(Clone, Debug)]
pub struct Battery {
    pub soc: f64, // state of charge 0..1
    pub voltage: f64,
    pub current: f64,
    pub capacity_ah: f64,
    pub cells: f64,
    pub temperature_c: f64,
    pub resistance25: f64, // Ω per cell
}

impl Battery {
    pub fn new(capacity_ah: f64, cells: f64, temperature_c: f64) -> Self {
        Battery { soc: 1.0, voltage: 12.6, current: 0.0, capacity_ah, cells, temperature_c, resistance25: 0.012 }
    }
    pub fn ocv_cell(&self) -> f64 {
        let s = self.soc;
        // A typical LiPo discharge curve: steep at both ends, flat in the middle.
        3.3 + 0.9 * s - 0.35 * (-12.0 * s).exp() + 0.1 * (-8.0 * (1.0 - s)).exp()
    }
    pub fn resistance_cell(&self) -> f64 {
        self.resistance25 * ((25.0 - self.temperature_c).max(0.0) * 0.03).exp()
    }
    pub fn usable_capacity(&self) -> f64 {
        self.capacity_ah * if self.temperature_c >= 15.0 { 1.0 } else { (1.0 - (15.0 - self.temperature_c) * 0.012).max(0.6) }
    }
    /// Draws `current` amps for dt seconds; returns the loaded pack voltage.
    pub fn draw(&mut self, current: f64, dt: f64) -> f64 {
        self.current = current;
        self.soc = (self.soc - current * dt / 3600.0 / self.usable_capacity()).max(0.0);
        // The pack warms itself under load (I²R), which helps in the cold.
        self.temperature_c += (current * current * self.resistance_cell() * self.cells / 25.0) * dt * 0.02;
        self.voltage = self.cells * (self.ocv_cell() - current * self.resistance_cell());
        self.voltage
    }
}

/// Current (A) of one motor making `thrust_n`: fits the F1404 table (≈ 9 A at its ≈ 1.8 N 3S
/// maximum, scaled from 17.5 A at 3.4 N on 4S) with the T^1.5 law of momentum theory.
pub fn motor_current(thrust_n: f64, max_thrust_n: f64) -> f64 {
    0.3 + 9.0 * (thrust_n.max(0.0) / max_thrust_n).powf(1.5)
}

/// The same curve for a motor that draws `peak_a` at full throttle (from its thrust table).
pub fn motor_current_peak(thrust_n: f64, max_thrust_n: f64, peak_a: f64) -> f64 {
    if (peak_a - 9.3).abs() < 1e-12 {
        return motor_current(thrust_n, max_thrust_n);
    }
    0.3 + (peak_a - 0.3).max(0.0) * (thrust_n.max(0.0) / max_thrust_n).powf(1.5)
}
