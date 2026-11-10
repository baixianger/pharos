use std::env;
use std::path::{Path, PathBuf};

/// Resolve the Cursor `agent` CLI (prefer `PHAROS_CURSOR_AGENT_EXECUTABLE`, then PATH).
pub fn resolve_agent_executable() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();
    if let Some(path) = env::var_os("PHAROS_CURSOR_AGENT_EXECUTABLE") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(path) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&path).map(|directory| directory.join("agent")));
    }
    candidates.extend([
        home_dir().join(".local/bin/agent"),
        PathBuf::from("/opt/homebrew/bin/agent"),
        PathBuf::from("/usr/local/bin/agent"),
    ]);
    candidates
        .into_iter()
        .find(|path| path.is_file())
        .and_then(|path| path.canonicalize().ok())
        .ok_or_else(|| {
            "Cursor agent CLI not found; set PHAROS_CURSOR_AGENT_EXECUTABLE or install `agent`"
                .to_string()
        })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_dir_is_non_empty() {
        assert!(!home_dir().as_os_str().is_empty());
    }
}
