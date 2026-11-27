//! Batched stepping (RUST-ENGINES 6.3, E-11): N independent worlds that share one model,
//! stepped in parallel with rayon. Each world owns its state and scratch, so the result of a
//! step does not depend on which thread ran it or in what order: a batch run is bitwise equal
//! to running the worlds one after another.

use std::sync::Arc;

use rayon::prelude::*;

use crate::error::{PhysError, params};
use crate::model::PhysModel;
use crate::world::{Settings, World};

/// N environments on one model.
pub struct Batch {
    pub worlds: Vec<World>,
    /// Worlds per rayon task (small worlds step in microseconds; grouping cuts scheduling).
    pub chunk: usize,
}

impl Batch {
    /// `n` worlds at the model's neutral configuration.
    pub fn new(model: Arc<PhysModel>, settings: Settings, n: usize) -> Self {
        let first = World::new(model, settings);
        Batch::from_world(&first, n)
    }

    /// `n` copies of a prepared world.
    pub fn from_world(w: &World, n: usize) -> Self {
        Batch { worlds: vec![w.clone(); n], chunk: 8 }
    }

    pub fn len(&self) -> usize {
        self.worlds.len()
    }

    pub fn is_empty(&self) -> bool {
        self.worlds.is_empty()
    }

    /// Number of actuators per world.
    pub fn na(&self) -> usize {
        self.worlds.first().map_or(0, |w| w.act.len())
    }

    /// Controls for every world, row-major `n x na`.
    pub fn set_controls(&mut self, controls: &[f64]) -> Result<(), PhysError> {
        let na = self.na();
        if controls.len() != self.len() * na {
            return Err(params(format!("controls: expected {} values ({} worlds x {na} actuators)", self.len() * na, self.len())));
        }
        for (w, c) in self.worlds.iter_mut().zip(controls.chunks(na.max(1))) {
            for (a, v) in c.iter().enumerate() {
                w.set_control(a, *v);
            }
        }
        Ok(())
    }

    /// Advances every world `steps` steps in parallel. The first error (lowest world index)
    /// is returned; the other worlds still advance.
    pub fn step(&mut self, steps: usize) -> Result<(), PhysError> {
        let chunk = self.chunk.max(1);
        let errors: Vec<Option<PhysError>> = self.worlds.par_iter_mut().with_min_len(chunk).map(|w| w.run(steps).err()).collect();
        match errors.into_iter().flatten().next() {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// The same steps one world after another (the determinism reference).
    pub fn step_serial(&mut self, steps: usize) -> Result<(), PhysError> {
        let mut first = None;
        for w in &mut self.worlds {
            if let Err(e) = w.run(steps) {
                first.get_or_insert(e);
            }
        }
        first.map_or(Ok(()), Err)
    }

    /// Positions of every world, row-major `n x nq`.
    pub fn q_flat(&self) -> Vec<f64> {
        self.worlds.iter().flat_map(|w| w.q.iter().copied()).collect()
    }

    /// Velocities of every world, row-major `n x nv`.
    pub fn v_flat(&self) -> Vec<f64> {
        self.worlds.iter().flat_map(|w| w.v.iter().copied()).collect()
    }
}
