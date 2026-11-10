use super::{
    AppServerTransport, MAX_PENDING_NOTIFICATIONS, capture_notification_into, response_result,
};
use crate::error::AdapterError;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::fs::File;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

struct ProxyStream {
    reader: ChildStdout,
    writer: ChildStdin,
}

impl Read for ProxyStream {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.reader.read(buffer)
    }
}

impl Write for ProxyStream {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        self.writer.write(buffer)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.writer.flush()
    }
}

/// Shared-daemon transport: `codex app-server daemon start` + `proxy` WebSocket.
/// Used by the JSONL helper binary that `pharos-meshd` spawns today.
pub struct DaemonProxyAppServer {
    _proxy: Child,
    stream: ProxyStream,
    fragment: Vec<u8>,
    notifications: VecDeque<Value>,
}

impl DaemonProxyAppServer {
    pub fn connect(executable: &Path) -> Result<Self, AdapterError> {
        let daemon = Command::new(executable)
            .args(["app-server", "daemon", "start"])
            .output()
            .map_err(|error| AdapterError::new(format!("start daemon: {error}")))?;
        if !daemon.status.success() {
            let detail = String::from_utf8_lossy(&daemon.stderr).trim().to_string();
            return Err(AdapterError::new(if detail.is_empty() {
                "daemon start failed".to_string()
            } else {
                detail
            }));
        }
        let mut proxy = Command::new(executable)
            .args(["app-server", "proxy"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|error| AdapterError::new(format!("start proxy: {error}")))?;
        let writer = proxy
            .stdin
            .take()
            .ok_or_else(|| AdapterError::new("proxy stdin unavailable"))?;
        let reader = proxy
            .stdout
            .take()
            .ok_or_else(|| AdapterError::new("proxy stdout unavailable"))?;
        let mut server = Self {
            _proxy: proxy,
            stream: ProxyStream { reader, writer },
            fragment: Vec::new(),
            notifications: VecDeque::new(),
        };
        server.handshake()?;
        Ok(server)
    }

    fn handshake(&mut self) -> Result<(), AdapterError> {
        let request = concat!(
            "GET / HTTP/1.1\r\n",
            "Host: localhost\r\n",
            "Upgrade: websocket\r\n",
            "Connection: Upgrade\r\n",
            "Sec-WebSocket-Key: cGhhcm9zLWNvZGV4LTAx\r\n",
            "Sec-WebSocket-Version: 13\r\n\r\n"
        );
        self.stream
            .write_all(request.as_bytes())
            .map_err(|error| AdapterError::new(error.to_string()))?;
        self.stream
            .flush()
            .map_err(|error| AdapterError::new(error.to_string()))?;
        let mut response = Vec::new();
        let mut byte = [0_u8; 1];
        while !response.ends_with(b"\r\n\r\n") && response.len() < 16 * 1024 {
            self.stream
                .read_exact(&mut byte)
                .map_err(|error| AdapterError::new(error.to_string()))?;
            response.push(byte[0]);
        }
        let header = String::from_utf8_lossy(&response);
        if !header
            .lines()
            .next()
            .is_some_and(|line| line.contains(" 101 "))
        {
            return Err(AdapterError::new(
                "Codex App Server rejected WebSocket upgrade",
            ));
        }
        Ok(())
    }

    fn write_frame(&mut self, opcode: u8, payload: &[u8]) -> Result<(), AdapterError> {
        let mut frame = vec![0x80 | opcode];
        match payload.len() {
            length if length < 126 => frame.push(0x80 | length as u8),
            length if length <= u16::MAX as usize => {
                frame.push(0x80 | 126);
                frame.extend_from_slice(&(length as u16).to_be_bytes());
            }
            length => {
                frame.push(0x80 | 127);
                frame.extend_from_slice(&(length as u64).to_be_bytes());
            }
        }
        let mut mask = [0_u8; 4];
        File::open("/dev/urandom")
            .and_then(|mut file| file.read_exact(&mut mask))
            .map_err(|error| AdapterError::new(error.to_string()))?;
        frame.extend_from_slice(&mask);
        frame.extend(
            payload
                .iter()
                .enumerate()
                .map(|(index, byte)| byte ^ mask[index % 4]),
        );
        self.stream
            .write_all(&frame)
            .map_err(|error| AdapterError::new(error.to_string()))?;
        self.stream
            .flush()
            .map_err(|error| AdapterError::new(error.to_string()))
    }

    fn read_frame(&mut self) -> Result<(bool, u8, Vec<u8>), AdapterError> {
        let mut header = [0_u8; 2];
        self.stream
            .read_exact(&mut header)
            .map_err(|error| AdapterError::new(error.to_string()))?;
        let finished = header[0] & 0x80 != 0;
        let opcode = header[0] & 0x0f;
        let masked = header[1] & 0x80 != 0;
        let mut length = u64::from(header[1] & 0x7f);
        if length == 126 {
            let mut extended = [0_u8; 2];
            self.stream
                .read_exact(&mut extended)
                .map_err(|error| AdapterError::new(error.to_string()))?;
            length = u64::from(u16::from_be_bytes(extended));
        } else if length == 127 {
            let mut extended = [0_u8; 8];
            self.stream
                .read_exact(&mut extended)
                .map_err(|error| AdapterError::new(error.to_string()))?;
            length = u64::from_be_bytes(extended);
        }
        let length =
            usize::try_from(length).map_err(|_| AdapterError::new("WebSocket frame too large"))?;
        let mut mask = [0_u8; 4];
        if masked {
            self.stream
                .read_exact(&mut mask)
                .map_err(|error| AdapterError::new(error.to_string()))?;
        }
        let mut payload = vec![0_u8; length];
        self.stream
            .read_exact(&mut payload)
            .map_err(|error| AdapterError::new(error.to_string()))?;
        if masked {
            for (index, byte) in payload.iter_mut().enumerate() {
                *byte ^= mask[index % 4];
            }
        }
        Ok((finished, opcode, payload))
    }

    fn capture_payload(&mut self, payload: &[u8]) -> Result<(), AdapterError> {
        let message: Value = serde_json::from_slice(payload)
            .map_err(|error| AdapterError::new(error.to_string()))?;
        capture_notification_into(&mut self.notifications, &message, MAX_PENDING_NOTIFICATIONS);
        Ok(())
    }
}

impl AppServerTransport for DaemonProxyAppServer {
    fn request(&mut self, id: Value, method: &str, params: Value) -> Result<Value, AdapterError> {
        let payload = serde_json::to_vec(&json!({"id": id, "method": method, "params": params}))
            .map_err(|error| AdapterError::new(error.to_string()))?;
        self.write_frame(0x1, &payload)?;
        loop {
            let (finished, opcode, payload) = self.read_frame()?;
            match opcode {
                0x0 => {
                    self.fragment.extend_from_slice(&payload);
                    if finished {
                        let message = std::mem::take(&mut self.fragment);
                        if let Some(result) = response_for_bytes(&message, &id)? {
                            return Ok(result);
                        }
                        self.capture_payload(&message)?;
                    }
                }
                0x1 if finished => {
                    if let Some(result) = response_for_bytes(&payload, &id)? {
                        return Ok(result);
                    }
                    self.capture_payload(&payload)?;
                }
                0x1 => {
                    self.fragment.clear();
                    self.fragment.extend_from_slice(&payload);
                }
                0x8 => {
                    return Err(AdapterError::new("Codex App Server closed the connection"));
                }
                0x9 => self.write_frame(0xA, &payload)?,
                _ => {}
            }
        }
    }

    fn take_notifications(&mut self) -> Vec<Value> {
        self.notifications.drain(..).collect()
    }

    fn close(&mut self) {
        let _ = self._proxy.kill();
    }
}

fn response_for_bytes(payload: &[u8], expected_id: &Value) -> Result<Option<Value>, AdapterError> {
    let message: Value =
        serde_json::from_slice(payload).map_err(|error| AdapterError::new(error.to_string()))?;
    response_result(&message, expected_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn matches_only_expected_response_id() {
        assert!(
            response_for_bytes(br#"{"id":"other","result":1}"#, &Value::from("wanted"))
                .unwrap()
                .is_none()
        );
        let result = response_for_bytes(
            br#"{"id":"wanted","result":{"ok":true}}"#,
            &Value::from("wanted"),
        )
        .unwrap()
        .unwrap();
        assert_eq!(result["ok"], true);
    }

    #[test]
    fn surfaces_app_server_error_message() {
        let error = response_for_bytes(
            br#"{"id":1,"error":{"code":-1,"message":"not available"}}"#,
            &Value::from(1),
        )
        .unwrap_err();
        assert_eq!(error.message, "not available");
    }

    #[test]
    fn notification_capture_is_bounded_and_excludes_responses() {
        let mut queue = VecDeque::new();
        capture_notification_into(
            &mut queue,
            &json!({"method":"turn/started","params":{"threadId":"t1"}}),
            2,
        );
        capture_notification_into(&mut queue, &json!({"id":1,"result":{}}), 2);
        capture_notification_into(
            &mut queue,
            &json!({"method":"turn/completed","params":{"threadId":"t1"}}),
            2,
        );
        capture_notification_into(
            &mut queue,
            &json!({"method":"thread/status/changed","params":{"threadId":"t1"}}),
            2,
        );
        assert_eq!(queue.len(), 2);
        assert_eq!(queue.front().unwrap()["method"], "turn/completed");
    }
}
