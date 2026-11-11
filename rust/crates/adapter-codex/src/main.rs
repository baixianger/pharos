fn main() {
    if let Err(error) = pharos_codex_adapter::run_jsonl_daemon_proxy_bridge() {
        eprintln!("pharos-codex-adapter: {error}");
        std::process::exit(1);
    }
}
