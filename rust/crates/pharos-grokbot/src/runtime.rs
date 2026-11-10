//! Thin JSON-RPC client for the local Agent Runtime UDS (`pharos-meshd`).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum RuntimeError {
    #[error("runtime unavailable: {0}")]
    Unavailable(String),
    #[error("runtime rpc: {0}")]
    Rpc(String),
    #[error("invalid response")]
    InvalidResponse,
}

pub struct RuntimeClient {
    socket: PathBuf,
}

impl RuntimeClient {
    pub fn new(socket: impl Into<PathBuf>) -> Self {
        Self {
            socket: socket.into(),
        }
    }

    pub fn from_env_or(default: impl AsRef<Path>) -> Self {
        let path = std::env::var_os("PHAROS_AGENT_RUNTIME_SOCKET")
            .map(PathBuf::from)
            .unwrap_or_else(|| default.as_ref().to_path_buf());
        Self::new(path)
    }

    pub fn call(&self, method: &str, params: Value) -> Result<Value, RuntimeError> {
        let id = Uuid::new_v4().to_string();
        let request = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        let mut stream = UnixStream::connect(&self.socket)
            .map_err(|e| RuntimeError::Unavailable(format!("{}: {e}", self.socket.display())))?;
        stream.set_read_timeout(Some(Duration::from_secs(5))).ok();
        stream.set_write_timeout(Some(Duration::from_secs(5))).ok();
        let mut line =
            serde_json::to_vec(&request).map_err(|e| RuntimeError::Rpc(e.to_string()))?;
        line.push(b'\n');
        stream
            .write_all(&line)
            .map_err(|e| RuntimeError::Unavailable(e.to_string()))?;
        stream
            .flush()
            .map_err(|e| RuntimeError::Unavailable(e.to_string()))?;
        let mut reader = BufReader::new(stream);
        let mut response = String::new();
        reader
            .read_line(&mut response)
            .map_err(|e| RuntimeError::Unavailable(e.to_string()))?;
        if response.is_empty() {
            return Err(RuntimeError::InvalidResponse);
        }
        let value: Value =
            serde_json::from_str(&response).map_err(|_| RuntimeError::InvalidResponse)?;
        if let Some(err) = value.get("error") {
            let msg = err
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("runtime error");
            return Err(RuntimeError::Rpc(msg.to_string()));
        }
        value
            .get("result")
            .cloned()
            .ok_or(RuntimeError::InvalidResponse)
    }
}
