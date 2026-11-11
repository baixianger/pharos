//! In-process fan-out for `/api/v1/events` WebSocket frames (`ClientEvent`).

use pharos_api::ClientEvent;
use tokio::sync::broadcast;

/// Publish side used by services / fakes to push WS events.
#[derive(Clone, Debug)]
pub struct EventBus {
    tx: broadcast::Sender<ClientEvent>,
}

/// Subscribe side handed to each WebSocket connection.
pub struct EventSubscriber {
    rx: broadcast::Receiver<ClientEvent>,
}

impl EventBus {
    pub fn new(capacity: usize) -> Self {
        let (tx, _) = broadcast::channel(capacity);
        Self { tx }
    }

    pub fn publish(&self, event: ClientEvent) {
        // Lagging / zero-subscriber is fine — WS clients come and go.
        let _ = self.tx.send(event);
    }

    pub fn subscribe(&self) -> EventSubscriber {
        EventSubscriber {
            rx: self.tx.subscribe(),
        }
    }

    pub fn receiver_count(&self) -> usize {
        self.tx.receiver_count()
    }
}

impl EventSubscriber {
    pub async fn recv(&mut self) -> Result<ClientEvent, broadcast::error::RecvError> {
        self.rx.recv().await
    }
}
