//! The phys side of a MuJoCo run: `world_new` parameters (a built-in, a kin model, or an
//! assembly plus scenario) become a phys [`World`] or [`Loaded`] scenario exactly as phys's
//! own facade builds them, so both engines start from one model, one initial state and one set
//! of drives. MuJoCo then runs the MJCF export of that model.

use serde_json::Value;
use viaform_phys::actuator::{ActuatorKind, ServoParams};
use viaform_phys::scenario::{self, Loaded};
use viaform_phys::{ModelBuilder, PhysError, Settings, World};

use crate::mjcf::{self, Mjcf};
use crate::params;

/// A phys world built from `world_new` parameters.
pub enum Built {
    World(Box<World>),
    Scenario(Box<Loaded>),
}

impl Built {
    pub fn world(&self) -> &World {
        match self {
            Built::World(w) => w,
            Built::Scenario(s) => &s.world,
        }
    }
}

/// The engine `world_new` asks for: top-level `engine`, else the scenario's, else `phys`.
pub fn engine_of(p: &Value) -> &str {
    p.get("engine").and_then(Value::as_str).or_else(|| p.get("scenario").and_then(|s| s.get("engine")).and_then(Value::as_str)).unwrap_or("phys")
}

/// Builds the phys world of `world_new` parameters (no drone: MuJoCo has no rotor model).
pub fn build(p: &Value) -> Result<Built, PhysError> {
    let settings: Settings = match p.get("settings") {
        Some(s) => serde_json::from_value(s.clone()).map_err(|e| params(format!("settings: {e}")))?,
        None => Settings::default(),
    };
    if let (Some(a), Some(s)) = (p.get("assembly"), p.get("scenario")) {
        // The scenario names its engine; phys's loader runs it on phys's model either way.
        let mut s = s.clone();
        if let Some(o) = s.as_object_mut() {
            o.remove("engine");
        }
        return Ok(Built::Scenario(Box::new(scenario::load(a, &s)?)));
    }
    if p.get("drone").is_some() {
        return Err(PhysError::new("engine.unsupported", "the drone (rotors, drag, battery) runs on the phys engine only"));
    }
    let kin = if let Some(name) = p.get("builtin").and_then(Value::as_str) {
        viaform_kin::models::builtin(name).ok_or_else(|| PhysError::new("name.unknown", format!("no built-in model {name}")))?
    } else if let Some(m) = p.get("model") {
        let mut m: viaform_kin::Model = serde_json::from_value(m.clone()).map_err(|e| params(format!("model: {e}")))?;
        m.normalize()?;
        m
    } else {
        return Err(params("world_new needs builtin, model, or assembly + scenario"));
    };
    let kind: Option<ActuatorKind> = match p.get("actuator") {
        Some(a) => Some(serde_json::from_value(a.clone()).map_err(|e| params(format!("actuator: {e}")))?),
        None => None,
    };
    let mut b = ModelBuilder::new(kin);
    for a in 0..b.kin.actuators.len() {
        if b.kin.actuators[a].drive == viaform_kin::model::Drive::Motor {
            b.actuator(a, kind.clone().unwrap_or(ActuatorKind::Servo(ServoParams::default())));
        }
    }
    if p.get("ground").and_then(Value::as_bool).unwrap_or(false) {
        b.ground(0.8);
    }
    Ok(Built::World(Box::new(World::new(b.build()?, settings))))
}

/// The MJCF of `world_new` parameters (for the `mjcf_export` op and the simulate viewer).
pub fn export(p: &Value) -> Result<Mjcf, PhysError> {
    let built = build(p)?;
    let w = built.world();
    mjcf::export(&w.model, &w.settings)
}
