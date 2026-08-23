use pharos_agent_core::{AdapterRequest, AdapterResponse};
use serde_json::{Value, json};
use std::env;
use std::collections::VecDeque;
use std::fs::File;
use std::io::{self, BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

fn main() {
    if let Err(error) = run() {
        eprintln!("pharos-codex-adapter: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let executable = resolve_codex()?;
    let mut app_server = AppServer::connect(&executable)?;
    app_server.request(
        "pharos-initialize",
        "initialize",
        json!({
            "clientInfo": {"name": "pharos", "title": "Pharos", "version": "0.1.0"},
            "capabilities": {"experimentalApi": false}
        }),
    )?;

    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line.map_err(|error| error.to_string())?;
        if line.trim().is_empty() { continue; }
        let response = match serde_json::from_str::<AdapterRequest>(&line) {
            Ok(request) if request.method == "codex.events" => {
                let poll_id = format!("pharos-events-{}", request.id);
                match app_server.request(poll_id, "thread/list", json!({"limit": 1})) {
                    Ok(_) => AdapterResponse::success(request.id, json!({
                        "events": app_server.take_notifications()
                    })),
                    Err(error) => AdapterResponse::failure(request.id, error),
                }
            }
            Ok(request) => match app_server.request(
                request.id.clone(), &request.method, request.params,
            ) {
                Ok(result) => AdapterResponse::success(request.id, result),
                Err(error) => AdapterResponse::failure(request.id, error),
            },
            Err(error) => AdapterResponse::failure(Value::Null, format!("invalid request: {error}")),
        };
        serde_json::to_writer(&mut stdout, &response).map_err(|error| error.to_string())?;
        stdout.write_all(b"\n").map_err(|error| error.to_string())?;
        stdout.flush().map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn resolve_codex() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();
    if let Some(path) = env::var_os("PHAROS_CODEX_EXECUTABLE") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(path) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&path).map(|directory| directory.join("codex")));
    }
    candidates.extend([
        PathBuf::from("/opt/homebrew/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
        home_dir().join(".local/bin/codex"),
        PathBuf::from("/Applications/Codex.app/Contents/Resources/codex"),
    ]);
    candidates.into_iter().find(|path| path.is_file())
        .and_then(|path| path.canonicalize().ok())
        .ok_or_else(|| "codex executable not found; set PHAROS_CODEX_EXECUTABLE".to_string())
}

fn home_dir() -> PathBuf {
    env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

struct ProxyStream { reader: ChildStdout, writer: ChildStdin }

impl Read for ProxyStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> { self.reader.read(buffer) }
}

impl Write for ProxyStream {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> { self.writer.write(buffer) }
    fn flush(&mut self) -> io::Result<()> { self.writer.flush() }
}

const MAX_PENDING_NOTIFICATIONS: usize = 1_024;

struct AppServer {
    _proxy: Child,
    stream: ProxyStream,
    fragment: Vec<u8>,
    notifications: VecDeque<Value>,
}

impl AppServer {
    fn connect(executable: &Path) -> Result<Self, String> {
        let daemon = Command::new(executable).args(["app-server", "daemon", "start"])
            .output().map_err(|error| format!("start daemon: {error}"))?;
        if !daemon.status.success() {
            let detail = String::from_utf8_lossy(&daemon.stderr).trim().to_string();
            return Err(if detail.is_empty() { "daemon start failed".into() } else { detail });
        }
        let mut proxy = Command::new(executable).args(["app-server", "proxy"])
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit())
            .spawn().map_err(|error| format!("start proxy: {error}"))?;
        let writer = proxy.stdin.take().ok_or("proxy stdin unavailable")?;
        let reader = proxy.stdout.take().ok_or("proxy stdout unavailable")?;
        let mut server = Self {
            _proxy: proxy,
            stream: ProxyStream { reader, writer },
            fragment: Vec::new(),
            notifications: VecDeque::new(),
        };
        server.handshake()?;
        Ok(server)
    }

    fn handshake(&mut self) -> Result<(), String> {
        let request = concat!(
            "GET / HTTP/1.1\r\n", "Host: localhost\r\n", "Upgrade: websocket\r\n",
            "Connection: Upgrade\r\n", "Sec-WebSocket-Key: cGhhcm9zLWNvZGV4LTAx\r\n",
            "Sec-WebSocket-Version: 13\r\n\r\n"
        );
        self.stream.write_all(request.as_bytes()).map_err(|error| error.to_string())?;
        self.stream.flush().map_err(|error| error.to_string())?;
        let mut response = Vec::new();
        let mut byte = [0_u8; 1];
        while !response.ends_with(b"\r\n\r\n") && response.len() < 16 * 1024 {
            self.stream.read_exact(&mut byte).map_err(|error| error.to_string())?;
            response.push(byte[0]);
        }
        let header = String::from_utf8_lossy(&response);
        if !header.lines().next().is_some_and(|line| line.contains(" 101 ")) {
            return Err("Codex App Server rejected WebSocket upgrade".into());
        }
        Ok(())
    }

    fn request(&mut self, id: impl Into<Value>, method: &str, params: Value) -> Result<Value, String> {
        let id = id.into();
        let payload = serde_json::to_vec(&json!({"id": id, "method": method, "params": params}))
            .map_err(|error| error.to_string())?;
        self.write_frame(0x1, &payload)?;
        loop {
            let (finished, opcode, payload) = self.read_frame()?;
            match opcode {
                0x0 => {
                    self.fragment.extend_from_slice(&payload);
                    if finished {
                        let message = std::mem::take(&mut self.fragment);
                        if let Some(result) = response_for(&message, &id)? { return Ok(result); }
                        self.capture_notification(&message)?;
                    }
                }
                0x1 if finished => {
                    if let Some(result) = response_for(&payload, &id)? { return Ok(result); }
                    self.capture_notification(&payload)?;
                }
                0x1 => { self.fragment.clear(); self.fragment.extend_from_slice(&payload); }
                0x8 => return Err("Codex App Server closed the connection".into()),
                0x9 => self.write_frame(0xA, &payload)?,
                _ => {}
            }
        }
    }

    fn capture_notification(&mut self, payload: &[u8]) -> Result<(), String> {
        capture_notification_into(&mut self.notifications, payload, MAX_PENDING_NOTIFICATIONS)
    }

    fn take_notifications(&mut self) -> Vec<Value> {
        self.notifications.drain(..).collect()
    }

    fn write_frame(&mut self, opcode: u8, payload: &[u8]) -> Result<(), String> {
        let mut frame = vec![0x80 | opcode];
        match payload.len() {
            length if length < 126 => frame.push(0x80 | length as u8),
            length if length <= u16::MAX as usize => {
                frame.push(0x80 | 126); frame.extend_from_slice(&(length as u16).to_be_bytes());
            }
            length => { frame.push(0x80 | 127); frame.extend_from_slice(&(length as u64).to_be_bytes()); }
        }
        let mut mask = [0_u8; 4];
        File::open("/dev/urandom").and_then(|mut file| file.read_exact(&mut mask))
            .map_err(|error| error.to_string())?;
        frame.extend_from_slice(&mask);
        frame.extend(payload.iter().enumerate().map(|(index, byte)| byte ^ mask[index % 4]));
        self.stream.write_all(&frame).map_err(|error| error.to_string())?;
        self.stream.flush().map_err(|error| error.to_string())
    }

    fn read_frame(&mut self) -> Result<(bool, u8, Vec<u8>), String> {
        let mut header = [0_u8; 2];
        self.stream.read_exact(&mut header).map_err(|error| error.to_string())?;
        let finished = header[0] & 0x80 != 0;
        let opcode = header[0] & 0x0f;
        let masked = header[1] & 0x80 != 0;
        let mut length = u64::from(header[1] & 0x7f);
        if length == 126 {
            let mut extended = [0_u8; 2];
            self.stream.read_exact(&mut extended).map_err(|error| error.to_string())?;
            length = u64::from(u16::from_be_bytes(extended));
        } else if length == 127 {
            let mut extended = [0_u8; 8];
            self.stream.read_exact(&mut extended).map_err(|error| error.to_string())?;
            length = u64::from_be_bytes(extended);
        }
        let length = usize::try_from(length).map_err(|_| "WebSocket frame too large")?;
        let mut mask = [0_u8; 4];
        if masked { self.stream.read_exact(&mut mask).map_err(|error| error.to_string())?; }
        let mut payload = vec![0_u8; length];
        self.stream.read_exact(&mut payload).map_err(|error| error.to_string())?;
        if masked {
            for (index, byte) in payload.iter_mut().enumerate() { *byte ^= mask[index % 4]; }
        }
        Ok((finished, opcode, payload))
    }
}

fn response_for(payload: &[u8], expected_id: &Value) -> Result<Option<Value>, String> {
    let message: Value = serde_json::from_slice(payload).map_err(|error| error.to_string())?;
    if message.get("id") != Some(expected_id) { return Ok(None); }
    if let Some(error) = message.get("error") {
        let detail = error.get("message").and_then(Value::as_str)
            .map(str::to_owned).unwrap_or_else(|| error.to_string());
        return Err(detail);
    }
    Ok(Some(message.get("result").cloned().unwrap_or(Value::Null)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_only_expected_response_id() {
        assert!(response_for(br#"{"id":"other","result":1}"#, &Value::from("wanted")).unwrap().is_none());
        let result = response_for(br#"{"id":"wanted","result":{"ok":true}}"#, &Value::from("wanted"))
            .unwrap().unwrap();
        assert_eq!(result["ok"], true);
    }

    #[test]
    fn surfaces_app_server_error_message() {
        let error = response_for(br#"{"id":1,"error":{"code":-1,"message":"not available"}}"#,
            &Value::from(1)).unwrap_err();
        assert_eq!(error, "not available");
    }

    #[test]
    fn notification_capture_is_bounded_and_excludes_responses() {
        let notification = br#"{"method":"turn/started","params":{"threadId":"t1"}}"#;
        let response = br#"{"id":1,"result":{}}"#;
        let mut queue = VecDeque::new();
        capture_notification_into(&mut queue, notification, 2).unwrap();
        capture_notification_into(&mut queue, response, 2).unwrap();
        capture_notification_into(&mut queue,
            br#"{"method":"turn/completed","params":{"threadId":"t1"}}"#, 2).unwrap();
        capture_notification_into(&mut queue,
            br#"{"method":"thread/status/changed","params":{"threadId":"t1"}}"#, 2).unwrap();
        assert_eq!(queue.len(), 2);
        assert_eq!(queue.front().unwrap()["method"], "turn/completed");
    }
}

fn capture_notification_into(queue: &mut VecDeque<Value>, payload: &[u8], limit: usize)
    -> Result<(), String>
{
    let message: Value = serde_json::from_slice(payload).map_err(|error| error.to_string())?;
    if message.get("method").and_then(Value::as_str).is_none() || message.get("id").is_some() {
        return Ok(());
    }
    if queue.len() == limit { queue.pop_front(); }
    queue.push_back(message);
    Ok(())
}
