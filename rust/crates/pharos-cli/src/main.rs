//! Pharos Rust CLI (S1): `thread read` / `thread reply` / `grokbot serve`.
//!
//! Parity with Swift `pharos-mesh` Thread helpers documented in
//! `docs/agents/grokbot/threads/2026-11-10_protocol.md`.

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use pharos_grokbot::{
    DISPLAY_NICK, GrokbotThreadBridge, MEMBER_ID, RuntimeClient, default_webhook_env_path,
};
use pharos_thread::{ThreadService, open_thread_db};

fn main() -> ExitCode {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        return usage("thread read|reply … | grokbot serve …");
    }
    let cmd = args.remove(0);
    match cmd.as_str() {
        "thread" => run_thread(args),
        "grokbot" => run_grokbot(args),
        "-h" | "--help" | "help" => {
            print_usage();
            ExitCode::SUCCESS
        }
        other => usage(&format!("unknown command: {other}")),
    }
}

fn run_thread(mut args: Vec<String>) -> ExitCode {
    if args.is_empty() {
        return usage(
            "thread read --thread ID [--since MESSAGE-ID] [--limit N] [--data-dir PATH] | \
             thread reply --thread ID --as grokbot --text-file ABSOLUTE-PATH \
             [--message MESSAGE-ID] [--data-dir PATH]",
        );
    }
    let sub = args.remove(0);
    let data_dir = match option_path("--data-dir", &args) {
        Ok(Some(p)) => {
            if !p.is_absolute() {
                return usage("--data-dir requires an absolute path");
            }
            p
        }
        Ok(None) => default_data_dir(),
        Err(e) => return usage(&e),
    };
    let store = match open_thread_db(&data_dir) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::from(1);
        }
    };

    match sub.as_str() {
        "read" => {
            let Some(thread) = option("--thread", &args).filter(|s| !s.is_empty()) else {
                return usage(
                    "thread read --thread ID [--since MESSAGE-ID] [--limit N] [--data-dir PATH]",
                );
            };
            let limit = option("--limit", &args)
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(40);
            let since = option("--since", &args);
            match store.cli_read(&thread, Some(limit), since.as_deref()) {
                Ok(payload) => match serde_json::to_string_pretty(&payload) {
                    Ok(json) => {
                        println!("{json}");
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        ExitCode::from(1)
                    }
                },
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::from(1)
                }
            }
        }
        "reply" => {
            let thread = option("--thread", &args).filter(|s| !s.is_empty());
            let as_member = option("--as", &args);
            let text_path = option("--text-file", &args);
            let (Some(thread), Some(as_member), Some(text_path)) = (thread, as_member, text_path)
            else {
                return usage(
                    "thread reply --thread ID --as grokbot --text-file ABSOLUTE-PATH \
                     [--message MESSAGE-ID] [--data-dir PATH]",
                );
            };
            if as_member != MEMBER_ID {
                return usage(&format!(
                    "thread reply --as currently supports only {MEMBER_ID}"
                ));
            }
            if !text_path.starts_with('/') {
                return usage("--text-file requires an absolute path");
            }
            let text = match fs::read_to_string(&text_path) {
                Ok(t) => t.trim().to_string(),
                Err(e) => {
                    eprintln!("error: read text-file: {e}");
                    return ExitCode::from(1);
                }
            };
            if text.is_empty() {
                return usage("thread reply --text-file must be non-empty UTF-8");
            }
            // Ensure grokbot membership exists so replyOnce can resolve nick.
            if let Err(e) = store.join(
                &thread,
                MEMBER_ID,
                DISPLAY_NICK,
                Some(pharos_grokbot::AGENT_KIND),
            ) {
                eprintln!("error: {e}");
                return ExitCode::from(1);
            }
            let message = option("--message", &args).filter(|s| !s.is_empty());
            match store.cli_reply(&thread, &as_member, &text, message.as_deref()) {
                Ok(payload) => match serde_json::to_string(&payload) {
                    Ok(json) => {
                        println!("{json}");
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        ExitCode::from(1)
                    }
                },
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::from(1)
                }
            }
        }
        _ => usage(
            "thread read --thread ID [--since MESSAGE-ID] [--limit N] [--data-dir PATH] | \
             thread reply --thread ID --as grokbot --text-file ABSOLUTE-PATH \
             [--message MESSAGE-ID] [--data-dir PATH]",
        ),
    }
}

fn run_grokbot(mut args: Vec<String>) -> ExitCode {
    if args.first().map(String::as_str) != Some("serve") {
        return usage("grokbot serve [--data-dir PATH] [--host LABEL]");
    }
    args.remove(0);
    let data_dir = match option_path("--data-dir", &args) {
        Ok(Some(p)) => {
            if !p.is_absolute() {
                return usage("--data-dir requires an absolute path");
            }
            p
        }
        Ok(None) => default_data_dir(),
        Err(e) => return usage(&e),
    };
    let host = option("--host", &args)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(local_hostname);

    let store = match open_thread_db(&data_dir) {
        Ok(s) => Arc::new(s),
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::from(1);
        }
    };

    let client = RuntimeClient::from_env_or(default_runtime_socket());
    let store_hist = Arc::clone(&store);
    let bridge = GrokbotThreadBridge::with_runtime_client(
        client,
        Box::new(move |room| {
            store_hist
                .history_for_bridge(room, 40)
                .map_err(|e| e.to_string())
        }),
        host.clone(),
        Some(default_webhook_env_path()),
    );

    if let Err(e) = bridge.ensure_registered() {
        eprintln!("error: {e}");
        return ExitCode::from(1);
    }
    println!("grokbot serving member={MEMBER_ID} nick={DISPLAY_NICK} host={host}");
    loop {
        if let Err(e) = bridge.poll() {
            eprintln!("grokbot poll: {e}");
        }
        thread::sleep(Duration::from_millis(750));
    }
}

fn default_data_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
        .join("Library/Application Support/Pharos/Mesh")
}

fn default_runtime_socket() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
        .join("Library/Application Support/Pharos/Runtime/agent-runtime.sock")
}

fn option(name: &str, args: &[String]) -> Option<String> {
    args.windows(2).find_map(|w| {
        if w[0] == name {
            Some(w[1].clone())
        } else {
            None
        }
    })
}

fn option_path(name: &str, args: &[String]) -> Result<Option<PathBuf>, String> {
    match option(name, args) {
        Some(p) => Ok(Some(PathBuf::from(p))),
        None => Ok(None),
    }
}

fn usage(detail: &str) -> ExitCode {
    eprintln!("usage: pharos {detail}");
    ExitCode::from(2)
}

fn print_usage() {
    eprintln!(
        "pharos — Rust CLI (RFC-007 S1)\n\n\
         thread read --thread ID [--since MESSAGE-ID] [--limit N] [--data-dir PATH]\n\
         thread reply --thread ID --as grokbot --text-file ABSOLUTE-PATH \
[--message MESSAGE-ID] [--data-dir PATH]\n\
         grokbot serve [--data-dir PATH] [--host LABEL]"
    );
}

fn local_hostname() -> String {
    if let Ok(h) = env::var("HOSTNAME")
        && !h.is_empty()
    {
        return h;
    }
    if let Ok(h) = fs::read_to_string("/etc/hostname") {
        let h = h.trim();
        if !h.is_empty() {
            return h.to_string();
        }
    }
    "localhost".into()
}
