//! Shared Axum state: service trait objects + event bus.

use std::sync::Arc;

use crate::services::{
    ApprovalService, AttachmentService, EventBus, InMemoryApprovalService,
    InMemoryAttachmentService, InMemoryMemberSettingsService, InMemoryThreadBindingService,
    MemberSettingsService, SessionService, ThreadBindingService, ThreadService,
};

/// Application state mounted on every API route.
#[derive(Clone)]
pub struct AppState {
    pub threads: Arc<dyn ThreadService>,
    pub sessions: Arc<dyn SessionService>,
    pub events: EventBus,
    /// Durable pending approvals snapshot (in-memory unless wired to a file).
    pub approvals: Arc<dyn ApprovalService>,
    /// Durable Thread ↔ session bindings (in-memory unless wired to a file).
    pub bindings: Arc<dyn ThreadBindingService>,
    /// Durable per-member settings / avatars (in-memory unless file-backed).
    pub members: Arc<dyn MemberSettingsService>,
    /// Durable session attachments (in-memory unless file-backed).
    pub attachments: Arc<dyn AttachmentService>,
}

impl AppState {
    /// Build state with the in-memory approval/store services (tests / fake server).
    pub fn new(
        threads: Arc<dyn ThreadService>,
        sessions: Arc<dyn SessionService>,
        events: EventBus,
    ) -> Self {
        Self::with_approvals(
            threads,
            sessions,
            events,
            Arc::new(InMemoryApprovalService::new()),
        )
    }

    /// Build state with an explicit approval service (e.g. `FileApprovalService`)
    /// and in-memory web-endpoint stores (bindings / members / attachments).
    pub fn with_approvals(
        threads: Arc<dyn ThreadService>,
        sessions: Arc<dyn SessionService>,
        events: EventBus,
        approvals: Arc<dyn ApprovalService>,
    ) -> Self {
        Self::with_extras(
            threads,
            sessions,
            events,
            approvals,
            Arc::new(InMemoryThreadBindingService::new()),
            Arc::new(InMemoryMemberSettingsService::new()),
            Arc::new(InMemoryAttachmentService::new()),
        )
    }

    /// Build state with every service supplied explicitly. `build_real_app_state`
    /// uses this to wire the file-backed stores under the Host data dir.
    pub fn with_extras(
        threads: Arc<dyn ThreadService>,
        sessions: Arc<dyn SessionService>,
        events: EventBus,
        approvals: Arc<dyn ApprovalService>,
        bindings: Arc<dyn ThreadBindingService>,
        members: Arc<dyn MemberSettingsService>,
        attachments: Arc<dyn AttachmentService>,
    ) -> Self {
        Self {
            threads,
            sessions,
            events,
            approvals,
            bindings,
            members,
            attachments,
        }
    }

    /// Persist approval lifecycle events published on the WS bus.
    ///
    /// Adapters / session services announce `ApprovalRequired` / `ApprovalUpdated`
    /// / `ApprovalResolved` / `ApprovalWithdrawn` on [`EventBus`]; without this
    /// tap a page reload would lose the approval because the event stream only
    /// carries *future* events. Call once per process/state after construction.
    pub fn spawn_approval_tap(&self) -> tokio::task::JoinHandle<()> {
        let mut subscriber = self.events.subscribe();
        let approvals = Arc::clone(&self.approvals);
        tokio::spawn(async move {
            loop {
                match subscriber.recv().await {
                    Ok(event) => {
                        if let Err(error) = approvals.apply_event(&event).await {
                            tracing::warn!(
                                ?error,
                                event = ?event,
                                "approval tap failed to persist approval event"
                            );
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                        tracing::warn!(
                            skipped,
                            "approval tap lagged; durable pending snapshot may be incomplete"
                        );
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        })
    }
}
