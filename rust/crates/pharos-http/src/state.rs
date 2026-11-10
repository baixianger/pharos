//! Shared Axum state: service trait objects + event bus.

use std::sync::Arc;

use crate::services::{EventBus, SessionService, ThreadService};

/// Application state mounted on every API route.
#[derive(Clone)]
pub struct AppState {
    pub threads: Arc<dyn ThreadService>,
    pub sessions: Arc<dyn SessionService>,
    pub events: EventBus,
}

impl AppState {
    pub fn new(
        threads: Arc<dyn ThreadService>,
        sessions: Arc<dyn SessionService>,
        events: EventBus,
    ) -> Self {
        Self {
            threads,
            sessions,
            events,
        }
    }
}
