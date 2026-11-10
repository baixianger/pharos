//! Session Goal / Todo persistence (RFC-007 S2) on `PHASE0_DDL`.

mod error;
mod store;

pub use error::GoalsError;
pub use store::{GoalsStore, open_goals_db};
