//! Thin Unix JSON-RPC client against `pharos-meshd` / agent-runtime socket.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum RuntimeClientError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("runtime rpc: {0}")]
    Rpc(String),
}

#[derive(Debug, Clone)]
pub struct RuntimeClient {
    socket: PathBuf,
}

impl RuntimeClient {
    pub fn new(socket: impl Into<PathBuf>) -> Self {
        Self {
            socket: socket.into(),
        }
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// Send one JSON-RPC request line and read one JSON response line.
    pub fn call_raw(&self, request_json: &str) -> Result<String, RuntimeClientError> {
        let mut stream = UnixStream::connect(&self.socket)?;
        stream.set_read_timeout(Some(Duration::from_secs(15)))?;
        stream.set_write_timeout(Some(Duration::from_secs(15)))?;
        let mut line = request_json.trim().to_string();
        if !line.ends_with('\n') {
            line.push('\n');
        }
        stream.write_all(line.as_bytes())?;
        stream.flush()?;
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        loop {
            let n = stream.read(&mut tmp)?;
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
            if buf.contains(&b'\n') {
                break;
            }
            if buf.len() > 4 * 1024 * 1024 {
                return Err(RuntimeClientError::Rpc("response too large".into()));
            }
        }
        let text = String::from_utf8_lossy(&buf);
        let response = text
            .lines()
            .next()
            .ok_or_else(|| RuntimeClientError::Rpc("empty response".into()))?
            .to_string();
        Ok(response)
    }
}
