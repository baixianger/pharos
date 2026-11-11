//! Iroh endpoint wrapper that exchanges one PHM1 request/response per bi-stream.

use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use iroh::endpoint::{Connection, RelayMode, presets};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey};
use thiserror::Error;
use tokio::sync::Mutex;
use tracing::{debug, warn};

use crate::frame::{FrameError, MeshStreamFrame, MeshStreamFrameKind, read_frame, write_frame};

/// Pharos mesh ALPN (Swift `DistributedMeshProtocol.alpn`).
pub const PHAROS_MESH_ALPN: &[u8] = b"me.pai.pharos/mesh/1";

#[derive(Debug, Error)]
pub enum MeshIrohError {
    #[error("iroh: {0}")]
    Iroh(String),
    #[error("frame: {0}")]
    Frame(#[from] FrameError),
    #[error("timeout waiting for peer response")]
    Timeout,
    #[error("no mesh request handler installed")]
    NoHandler,
    #[error("invalid endpoint id: {0}")]
    InvalidEndpointId(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

pub type BoxFut<T> = Pin<Box<dyn Future<Output = T> + Send>>;
pub type MeshRequestHandler =
    Arc<dyn Fn(MeshTransportExchange, EndpointId) -> BoxFut<MeshTransportExchange> + Send + Sync>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MeshTransportExchange {
    pub header: Vec<u8>,
    pub body: Option<Vec<u8>>,
}

#[derive(Debug, Clone)]
pub struct PeerDial {
    pub endpoint_id: EndpointId,
    pub addr: Option<EndpointAddr>,
}

/// Long-lived Iroh endpoint + router for Pharos mesh ALPN.
pub struct MeshIrohEndpoint {
    endpoint: Endpoint,
    router: Router,
    secret_key: SecretKey,
    handler: Arc<Mutex<Option<MeshRequestHandler>>>,
}

#[derive(Clone)]
struct MeshProtocol {
    handler: Arc<Mutex<Option<MeshRequestHandler>>>,
}

impl std::fmt::Debug for MeshProtocol {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MeshProtocol").finish_non_exhaustive()
    }
}

impl ProtocolHandler for MeshProtocol {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let remote = connection.remote_id();
        loop {
            let (mut send, mut recv) = match connection.accept_bi().await {
                Ok(stream) => stream,
                Err(err) => {
                    debug!(%remote, error = %err, "mesh accept_bi ended");
                    break;
                }
            };
            let request = match read_frame(&mut recv).await {
                Ok(frame) => frame,
                Err(err) => {
                    warn!(%remote, error = %err, "failed to read mesh request frame");
                    break;
                }
            };
            if request.kind != MeshStreamFrameKind::Request {
                warn!(%remote, "peer sent non-request frame on accept path");
                break;
            }
            let exchange = MeshTransportExchange {
                header: request.header,
                body: request.body,
            };
            let response = {
                let guard = self.handler.lock().await;
                let Some(handler) = guard.as_ref() else {
                    warn!(%remote, "no mesh request handler installed");
                    break;
                };
                let fut = handler(exchange, remote);
                drop(guard);
                fut.await
            };
            let frame = MeshStreamFrame {
                kind: MeshStreamFrameKind::Response,
                header: response.header,
                body: response.body,
            };
            if let Err(err) = write_frame(&mut send, &frame).await {
                warn!(%remote, error = %err, "failed to write mesh response frame");
                break;
            }
            let _ = send.finish();
        }
        Ok(())
    }
}

impl MeshIrohEndpoint {
    /// Bind a new endpoint. When `data_dir` is set, persist/restore the secret key
    /// under `{data_dir}/iroh-secret.key` (32 bytes).
    pub async fn bind(
        data_dir: Option<&Path>,
        relay_disabled: bool,
    ) -> Result<Self, MeshIrohError> {
        let secret_key = load_or_create_secret(data_dir)?;
        let mut builder = Endpoint::builder(presets::N0);
        builder = builder.secret_key(secret_key.clone());
        if relay_disabled {
            builder = builder.relay_mode(RelayMode::Disabled);
        }
        let endpoint = builder
            .bind()
            .await
            .map_err(|e| MeshIrohError::Iroh(e.to_string()))?;
        let handler = Arc::new(Mutex::new(None));
        let protocol = MeshProtocol {
            handler: Arc::clone(&handler),
        };
        let router = Router::builder(endpoint.clone())
            .accept(PHAROS_MESH_ALPN, protocol)
            .spawn();
        // Wait briefly for local addressing without requiring global discovery.
        let _ = tokio::time::timeout(Duration::from_secs(2), endpoint.online()).await;
        Ok(Self {
            endpoint,
            router,
            secret_key,
            handler,
        })
    }

    pub fn endpoint_id(&self) -> EndpointId {
        self.endpoint.id()
    }

    pub fn endpoint_addr(&self) -> EndpointAddr {
        self.endpoint.addr()
    }

    pub fn endpoint_id_string(&self) -> String {
        self.endpoint.id().to_string()
    }

    pub fn secret_key_bytes(&self) -> [u8; 32] {
        self.secret_key.to_bytes()
    }

    /// Install the application request handler used by the accept loop.
    pub async fn set_handler<F, Fut>(&self, f: F)
    where
        F: Fn(MeshTransportExchange, EndpointId) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = MeshTransportExchange> + Send + 'static,
    {
        let boxed: MeshRequestHandler = Arc::new(move |req, id| Box::pin(f(req, id)));
        let mut guard = self.handler.lock().await;
        *guard = Some(boxed);
    }

    /// Dial peer and exchange one request/response on a fresh bi-stream.
    pub async fn exchange(
        &self,
        peer: &PeerDial,
        request: MeshTransportExchange,
        timeout: Duration,
    ) -> Result<MeshTransportExchange, MeshIrohError> {
        let addr = peer
            .addr
            .clone()
            .unwrap_or_else(|| EndpointAddr::new(peer.endpoint_id));
        let connect = self.endpoint.connect(addr, PHAROS_MESH_ALPN);
        let conn = tokio::time::timeout(timeout, connect)
            .await
            .map_err(|_| MeshIrohError::Timeout)?
            .map_err(|e| MeshIrohError::Iroh(e.to_string()))?;
        let (mut send, mut recv) = conn
            .open_bi()
            .await
            .map_err(|e| MeshIrohError::Iroh(e.to_string()))?;
        let frame = MeshStreamFrame {
            kind: MeshStreamFrameKind::Request,
            header: request.header,
            body: request.body,
        };
        write_frame(&mut send, &frame).await?;
        send.finish()
            .map_err(|e| MeshIrohError::Iroh(e.to_string()))?;
        let response_frame = tokio::time::timeout(timeout, read_frame(&mut recv))
            .await
            .map_err(|_| MeshIrohError::Timeout)??;
        if response_frame.kind != MeshStreamFrameKind::Response {
            return Err(MeshIrohError::Iroh(
                "peer returned non-response frame".into(),
            ));
        }
        Ok(MeshTransportExchange {
            header: response_frame.header,
            body: response_frame.body,
        })
    }

    /// Shut the accept router down and close the endpoint.
    ///
    /// Used by tests to simulate a host going offline; safe to call from `&self`.
    pub async fn close(&self) -> Result<(), MeshIrohError> {
        self.router
            .shutdown()
            .await
            .map_err(|e| MeshIrohError::Iroh(e.to_string()))?;
        self.endpoint.close().await;
        Ok(())
    }

    pub async fn shutdown(self) -> Result<(), MeshIrohError> {
        self.close().await
    }
}

fn load_or_create_secret(data_dir: Option<&Path>) -> Result<SecretKey, MeshIrohError> {
    if let Some(dir) = data_dir {
        std::fs::create_dir_all(dir)?;
        let path = dir.join("iroh-secret.key");
        if path.exists() {
            let bytes = std::fs::read(&path)?;
            if bytes.len() != 32 {
                return Err(MeshIrohError::Iroh(format!(
                    "iroh-secret.key must be 32 bytes, got {}",
                    bytes.len()
                )));
            }
            let mut key = [0u8; 32];
            key.copy_from_slice(&bytes);
            return Ok(SecretKey::from_bytes(&key));
        }
        let key = SecretKey::generate();
        std::fs::write(&path, key.to_bytes())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        return Ok(key);
    }
    Ok(SecretKey::generate())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn loopback_exchange_over_iroh() {
        let server = MeshIrohEndpoint::bind(None, true)
            .await
            .expect("server bind");
        let client = MeshIrohEndpoint::bind(None, true)
            .await
            .expect("client bind");
        let server_id = server.endpoint_id();
        let server_addr = server.endpoint_addr();

        server
            .set_handler(|req, _remote| async move {
                let mut header = b"echo:".to_vec();
                header.extend_from_slice(&req.header);
                MeshTransportExchange {
                    header,
                    body: req.body,
                }
            })
            .await;

        tokio::time::sleep(Duration::from_millis(200)).await;

        let response = client
            .exchange(
                &PeerDial {
                    endpoint_id: server_id,
                    addr: Some(server_addr),
                },
                MeshTransportExchange {
                    header: b"hello".to_vec(),
                    body: Some(b"world".to_vec()),
                },
                Duration::from_secs(10),
            )
            .await
            .expect("exchange");
        assert_eq!(response.header, b"echo:hello");
        assert_eq!(response.body.as_deref(), Some(b"world".as_slice()));

        client.shutdown().await.ok();
        server.shutdown().await.ok();
    }

    #[tokio::test]
    async fn closed_endpoint_is_unreachable() {
        let server = MeshIrohEndpoint::bind(None, true)
            .await
            .expect("server bind");
        let client = MeshIrohEndpoint::bind(None, true)
            .await
            .expect("client bind");
        let peer = PeerDial {
            endpoint_id: server.endpoint_id(),
            addr: Some(server.endpoint_addr()),
        };
        server.close().await.expect("server close");
        let result = client
            .exchange(
                &peer,
                MeshTransportExchange {
                    header: b"hello".to_vec(),
                    body: None,
                },
                Duration::from_secs(2),
            )
            .await;
        assert!(result.is_err(), "closed endpoint must not accept exchanges");
        client.shutdown().await.ok();
    }
}
