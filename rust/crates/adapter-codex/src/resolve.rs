use std::env;
use std::path::{Path, PathBuf};

/// Resolve the Codex CLI executable (prefer `PHAROS_CODEX_EXECUTABLE`, then PATH).
pub fn resolve_codex_executable() -> Result<PathBuf, String> {
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
    candidates
        .into_iter()
        .find(|path| path.is_file())
        .and_then(|path| path.canonicalize().ok())
        .ok_or_else(|| "codex executable not found; set PHAROS_CODEX_EXECUTABLE".to_string())
}

pub fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

pub fn ensure_executable(path: &Path) -> Result<PathBuf, String> {
    if !path.is_file() {
        return Err(format!("not an executable file: {}", path.display()));
    }
    path.canonicalize()
        .map_err(|error| format!("canonicalize {}: {error}", path.display()))
}
