//! Goal/Todo R/W smoke on an isolated msg-test data dir.
//!
//! Always runs (no live vendor). Prefers `~/personal/pharos-msg-test/...`.

use pharos_api::{SessionTodo, TodoStatus};
use pharos_goals::open_goals_db;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn msg_test_root() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    home.join("personal/pharos-msg-test")
}

#[test]
fn goal_todo_smoke_isolated_msg_test_dir() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let preferred = msg_test_root()
        .join("peer-hitl")
        .join(format!("rust-session-goals-{stamp}"));
    let data_dir = match fs::create_dir_all(&preferred) {
        Ok(()) => preferred,
        Err(err) => {
            eprintln!("msg-test dir unavailable ({err}); using tempdir");
            let dir = tempfile::tempdir().expect("tempdir");
            let path = dir.path().to_path_buf();
            // Keep contents for evidence by leaking TempDir into a permanent copy.
            fs::create_dir_all(&path).ok();
            std::mem::forget(dir);
            path
        }
    };
    eprintln!("goals smoke data_dir={}", data_dir.display());

    let store = open_goals_db(&data_dir).expect("open goals db");
    store
        .set_goal("sess-smoke", "S2 Goal/Todo smoke", "active")
        .expect("set goal");
    store
        .replace_todos(
            "sess-smoke",
            &[
                SessionTodo {
                    text: "write".into(),
                    status: TodoStatus::Completed,
                    priority: Some("p0".into()),
                },
                SessionTodo {
                    text: "read".into(),
                    status: TodoStatus::InProgress,
                    priority: None,
                },
            ],
        )
        .expect("replace todos");

    let progress = store.progress("sess-smoke").expect("progress");
    assert_eq!(
        progress.goal.as_ref().map(|g| g.objective.as_str()),
        Some("S2 Goal/Todo smoke")
    );
    assert_eq!(progress.todos.len(), 2);
    assert_eq!(progress.todos[0].status, TodoStatus::Completed);
    assert_eq!(progress.todos[1].text, "read");

    let store2 = open_goals_db(&data_dir).expect("reopen");
    let again = store2.progress("sess-smoke").expect("progress again");
    assert_eq!(again.todos.len(), 2);
    eprintln!(
        "goals smoke PASS session=sess-smoke objective={:?} todos={}",
        again.goal.as_ref().map(|g| &g.objective),
        again.todos.len()
    );
}
