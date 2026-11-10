use std::env;
use std::path::{Path, PathBuf};

/// Resolve the Agy CLI executable (prefer `PHAROS_AGY_EXECUTABLE`, then PATH).
pub fn resolve_agy_executable() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();
    if let Some(path) = env::var_os("PHAROS_AGY_EXECUTABLE") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(path) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&path).map(|directory| directory.join("agy")));
    }
    candidates.extend([
        home_dir().join(".local/bin/agy"),
        PathBuf::from("/opt/homebrew/bin/agy"),
        PathBuf::from("/usr/local/bin/agy"),
        PathBuf::from("/usr/bin/agy"),
    ]);
    candidates
        .into_iter()
        .find(|path| path.is_file())
        .and_then(|path| path.canonicalize().ok())
        .ok_or_else(|| "agy executable not found; set PHAROS_AGY_EXECUTABLE".to_string())
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

/// Convenience: msg-test data directory root for live evidence.
pub fn msg_test_root() -> PathBuf {
    home_dir().join("personal/pharos-msg-test")
}

/// Default Gemini app-state parent (`~/.gemini`). Adapter never edits this
/// beyond spawning `agy`, which reads auth itself.
pub fn default_gemini_dir() -> PathBuf {
    home_dir().join(".gemini")
}
