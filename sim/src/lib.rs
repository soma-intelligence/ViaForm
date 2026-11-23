//! ViaForm's drone simulation, the one copy every front end and the training run: a 6-DOF
//! 3-inch quad in seven weathers, a realistic plant and sensors, the flight controller
//! (cascaded PID or INDI with a learned residual), mapping and planning on time-of-flight
//! sensors, the race, and the training that tunes them. `api` is the JSON facade the apps use.

pub mod airframe;
pub mod api;
pub mod components;
pub mod control;
pub mod flight;
pub mod frame;
pub mod job;
pub mod mapping;
pub mod math;
pub mod parts;
pub mod physics;
pub mod planner;
pub mod policy;
pub mod race;
pub mod realism;
pub mod stable;
pub mod trained;
pub mod weather;
pub mod world;
pub mod train;
