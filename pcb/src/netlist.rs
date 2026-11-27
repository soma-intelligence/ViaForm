//! Netlist extraction from the schematic.
//!
//! Pins join through wires, through direct net assignments (`net.connect`), through labels that
//! share a name and through power symbols that share a value. Each connected group becomes one
//! net. A group that holds a user-named net keeps it (the lowest id when two meet, reported by
//! ERC); a group of two or more pins with no named net gets an extracted net named after its
//! first pin, whose id is reused across extractions while the name stays the same.

use crate::model::*;
use std::collections::{BTreeMap, BTreeSet};

struct Dsu {
    p: Vec<usize>,
}

impl Dsu {
    fn new(n: usize) -> Self {
        Dsu { p: (0..n).collect() }
    }
    fn find(&mut self, x: usize) -> usize {
        let mut r = x;
        while self.p[r] != r {
            r = self.p[r];
        }
        let mut c = x;
        while self.p[c] != r {
            let n = self.p[c];
            self.p[c] = r;
            c = n;
        }
        r
    }
    fn union(&mut self, a: usize, b: usize) {
        let (ra, rb) = (self.find(a), self.find(b));
        if ra != rb {
            // Smaller index wins: deterministic roots.
            let (lo, hi) = if ra < rb { (ra, rb) } else { (rb, ra) };
            self.p[hi] = lo;
        }
    }
}

/// Every pin of every component, in component then symbol order.
pub fn all_pins(p: &Project) -> Vec<(PinRef, PinKind)> {
    let mut v = vec![];
    for c in &p.components {
        if let Some(s) = p.symbol_of(c) {
            for pin in &s.pins {
                v.push((PinRef { component: c.id, pin: pin.number.clone() }, pin.kind));
            }
        }
    }
    v
}

/// Result of extraction: pin to net, plus nets that were merged into one group.
#[derive(Default, Debug, Clone)]
pub struct Netlist {
    pub pin_net: BTreeMap<PinRef, Id>,
    /// Groups where several user-named nets met: (kept, others).
    pub merged: Vec<(Id, Vec<Id>)>,
}

/// Rebuilds the nets of `p` from its schematic, in place, and returns the pin map.
pub fn extract(p: &mut Project) -> Netlist {
    let pins = all_pins(p);
    let index: BTreeMap<PinRef, usize> = pins.iter().enumerate().map(|(i, (r, _))| (r.clone(), i)).collect();
    // Nodes: pins, then one node per user-named net, then one per label name.
    let named: Vec<Id> = p.nets.iter().filter(|n| n.named).map(|n| n.id).collect();
    let mut label_names: BTreeSet<String> = p.labels.iter().map(|l| l.name.clone()).collect();
    for c in &p.components {
        if p.symbol_of(c).map(|s| s.power).unwrap_or(false) {
            label_names.insert(c.value.clone());
        }
    }
    let label_names: Vec<String> = label_names.into_iter().collect();
    let n_pins = pins.len();
    let net_node = |id: Id| n_pins + named.iter().position(|x| *x == id).unwrap();
    let label_node = |name: &str| n_pins + named.len() + label_names.iter().position(|x| x == name).unwrap();
    let mut d = Dsu::new(n_pins + named.len() + label_names.len());

    for w in &p.wires {
        if let (Some(a), Some(b)) = (index.get(&w.from), index.get(&w.to)) {
            d.union(*a, *b);
        }
    }
    for n in p.nets.iter().filter(|n| n.named) {
        for r in &n.pins {
            if let Some(i) = index.get(r) {
                d.union(*i, net_node(n.id));
            }
        }
        // A net named like a label or power symbol is that label's net.
        if label_names.contains(&n.name) {
            d.union(net_node(n.id), label_node(&n.name));
        }
    }
    for l in &p.labels {
        if let Some(i) = index.get(&l.pin) {
            d.union(*i, label_node(&l.name));
        }
    }
    for c in &p.components {
        if p.symbol_of(c).map(|s| s.power).unwrap_or(false) {
            if let Some(i) = index.get(&PinRef { component: c.id, pin: "1".into() }) {
                d.union(*i, label_node(&c.value));
            }
        }
    }

    // Groups in order of their root.
    let mut groups: BTreeMap<usize, (Vec<usize>, Vec<Id>, Vec<String>)> = BTreeMap::new();
    for i in 0..n_pins {
        let r = d.find(i);
        groups.entry(r).or_default().0.push(i);
    }
    for id in &named {
        let r = d.find(net_node(*id));
        groups.entry(r).or_default().1.push(*id);
    }
    for name in &label_names {
        let r = d.find(label_node(name));
        groups.entry(r).or_default().2.push(name.clone());
    }

    let mut out = Netlist::default();
    let old_auto: BTreeMap<String, Id> = p.nets.iter().filter(|n| !n.named).map(|n| (n.name.clone(), n.id)).collect();
    let mut keep: BTreeSet<Id> = named.iter().copied().collect();
    let mut new_nets: Vec<Net> = vec![];
    for (_, (members, nets, labels)) in groups {
        let net_id = if let Some(first) = nets.iter().min() {
            if nets.len() > 1 {
                out.merged.push((*first, nets.iter().filter(|x| *x != first).copied().collect()));
            }
            Some(*first)
        } else if !labels.is_empty() {
            // A label or power symbol without a net yet: create the named net.
            let name = labels[0].clone();
            let id = p.alloc();
            new_nets.push(Net { id, name, named: true, pins: vec![], class: None });
            keep.insert(id);
            Some(id)
        } else if members.len() >= 2 {
            let (r, _) = &pins[members[0]];
            let c = p.component(r.component).map(|c| c.reference.clone()).unwrap_or_default();
            let name = format!("Net-({c}-Pad{})", r.pin);
            let id = match old_auto.get(&name) {
                Some(id) => *id,
                None => {
                    let id = p.alloc();
                    new_nets.push(Net { id, name, named: false, pins: vec![], class: None });
                    id
                }
            };
            keep.insert(id);
            Some(id)
        } else {
            None
        };
        if let Some(id) = net_id {
            for m in members {
                out.pin_net.insert(pins[m].0.clone(), id);
            }
        }
    }
    p.nets.extend(new_nets);
    p.nets.retain(|n| keep.contains(&n.id));
    p.nets.sort_by_key(|n| n.id);
    for w in &mut p.wires {
        w.net = out.pin_net.get(&w.from).copied().unwrap_or(0);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn comp(p: &mut Project, kind: &str, r: &str) -> Id {
        let id = p.alloc();
        p.components.push(Component {
            id,
            sheet: p.sheets[0].id,
            reference: r.into(),
            value: kind.into(),
            kind: kind.into(),
            symbol: kind.into(),
            footprint: None,
            position: Default::default(),
            rotation: 0,
            no_connect: vec![],
        });
        id
    }

    #[test]
    fn wires_labels_and_named_nets() {
        let mut p = Project::default();
        let r1 = comp(&mut p, "resistor", "R1");
        let r2 = comp(&mut p, "resistor", "R2");
        let r3 = comp(&mut p, "resistor", "R3");
        let w = p.alloc();
        p.wires.push(Wire { id: w, from: PinRef { component: r1, pin: "2".into() }, to: PinRef { component: r2, pin: "1".into() }, net: 0 });
        let l1 = p.alloc();
        p.labels.push(Label { id: l1, name: "SIG".into(), pin: PinRef { component: r2, pin: "2".into() } });
        let l2 = p.alloc();
        p.labels.push(Label { id: l2, name: "SIG".into(), pin: PinRef { component: r3, pin: "1".into() } });
        let nl = extract(&mut p);
        let a = nl.pin_net[&PinRef { component: r1, pin: "2".into() }];
        assert_eq!(nl.pin_net[&PinRef { component: r2, pin: "1".into() }], a);
        let sig = nl.pin_net[&PinRef { component: r2, pin: "2".into() }];
        assert_eq!(nl.pin_net[&PinRef { component: r3, pin: "1".into() }], sig);
        assert_eq!(p.net_name(sig), "SIG");
        assert_eq!(p.net_name(a), "Net-(R1-Pad2)");
        // Same input, same ids.
        let again = extract(&mut p);
        assert_eq!(again.pin_net, nl.pin_net);
    }
}
