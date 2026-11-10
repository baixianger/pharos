//! SQLite Goal/Todo store using `pharos-store-schema` PHASE0 tables.

use std::path::{Path, PathBuf};

use pharos_api::{SessionGoal, SessionProgress, SessionTodo, TodoStatus};
use pharos_store_schema::{MIGRATIONS, MIGRATIONS_TABLE, PHASE0_DDL, paths};
use rusqlite::{Connection, OptionalExtension, params};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::error::GoalsError;

pub struct GoalsStore {
    conn: Connection,
}

pub fn open_goals_db(data_dir: &Path) -> Result<GoalsStore, GoalsError> {
    std::fs::create_dir_all(data_dir)?;
    let db_path = data_dir.join("goals.sqlite3");
    GoalsStore::open_path(&db_path)
}

impl GoalsStore {
    pub fn open_path(path: &Path) -> Result<Self, GoalsError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        conn.execute_batch(PHASE0_DDL)?;
        for migration in MIGRATIONS {
            let already: Option<i64> = conn
                .query_row(
                    &format!("SELECT version FROM {MIGRATIONS_TABLE} WHERE version = ?1"),
                    params![migration.version as i64],
                    |row| row.get(0),
                )
                .optional()?;
            if already.is_none() {
                let now = OffsetDateTime::now_utc()
                    .format(&Rfc3339)
                    .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
                conn.execute(
                    &format!(
                        "INSERT INTO {MIGRATIONS_TABLE} (version, name, applied_at) VALUES (?1, ?2, ?3)"
                    ),
                    params![migration.version as i64, migration.name, now],
                )?;
            }
        }
        Ok(Self { conn })
    }

    /// Convenience path under an isolated Host data-dir (`mesh/` sibling).
    pub fn default_path_under(data_dir: &Path) -> PathBuf {
        data_dir.join(paths::MESH_DIR).join("goals.sqlite3")
    }

    pub fn set_goal(
        &self,
        session_id: &str,
        objective: &str,
        status: &str,
    ) -> Result<SessionGoal, GoalsError> {
        let now = OffsetDateTime::now_utc()
            .format(&Rfc3339)
            .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
        self.conn.execute(
            "INSERT INTO session_goals (session_id, objective, status, updated_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(session_id) DO UPDATE SET
               objective = excluded.objective,
               status = excluded.status,
               updated_at = excluded.updated_at",
            params![session_id, objective, status, now],
        )?;
        Ok(SessionGoal {
            objective: objective.to_owned(),
            status: status.to_owned(),
        })
    }

    pub fn clear_goal(&self, session_id: &str) -> Result<(), GoalsError> {
        self.conn.execute(
            "DELETE FROM session_goals WHERE session_id = ?1",
            params![session_id],
        )?;
        Ok(())
    }

    pub fn replace_todos(
        &self,
        session_id: &str,
        todos: &[SessionTodo],
    ) -> Result<Vec<SessionTodo>, GoalsError> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM session_todos WHERE session_id = ?1",
            params![session_id],
        )?;
        for (idx, todo) in todos.iter().enumerate() {
            let status = todo_status_wire(todo.status);
            tx.execute(
                "INSERT INTO session_todos (session_id, text, status, priority, position)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![session_id, todo.text, status, todo.priority, idx as i64],
            )?;
        }
        tx.commit()?;
        Ok(todos.to_vec())
    }

    pub fn progress(&self, session_id: &str) -> Result<SessionProgress, GoalsError> {
        let goal = self
            .conn
            .query_row(
                "SELECT objective, status FROM session_goals WHERE session_id = ?1",
                params![session_id],
                |row| {
                    Ok(SessionGoal {
                        objective: row.get(0)?,
                        status: row.get(1)?,
                    })
                },
            )
            .optional()?;
        let mut stmt = self.conn.prepare(
            "SELECT text, status, priority FROM session_todos
             WHERE session_id = ?1 ORDER BY position ASC",
        )?;
        let todos = stmt
            .query_map(params![session_id], |row| {
                let status_raw: String = row.get(1)?;
                Ok(SessionTodo {
                    text: row.get(0)?,
                    status: parse_todo_status(&status_raw),
                    priority: row.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(SessionProgress { goal, todos })
    }
}

fn todo_status_wire(status: TodoStatus) -> &'static str {
    match status {
        TodoStatus::Pending => "pending",
        TodoStatus::InProgress => "inProgress",
        TodoStatus::Completed => "completed",
        TodoStatus::Unknown => "unknown",
    }
}

fn parse_todo_status(raw: &str) -> TodoStatus {
    match raw {
        "pending" => TodoStatus::Pending,
        "inProgress" | "in_progress" => TodoStatus::InProgress,
        "completed" => TodoStatus::Completed,
        _ => TodoStatus::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn goal_and_todo_roundtrip() {
        let dir = tempdir().unwrap();
        let store = open_goals_db(dir.path()).unwrap();
        store
            .set_goal("sess-1", "Ship S2 HITL", "in_progress")
            .unwrap();
        store
            .replace_todos(
                "sess-1",
                &[
                    SessionTodo {
                        text: "unit webhook".into(),
                        status: TodoStatus::Completed,
                        priority: Some("high".into()),
                    },
                    SessionTodo {
                        text: "live codex".into(),
                        status: TodoStatus::InProgress,
                        priority: None,
                    },
                ],
            )
            .unwrap();
        let progress = store.progress("sess-1").unwrap();
        assert_eq!(progress.goal.as_ref().unwrap().objective, "Ship S2 HITL");
        assert_eq!(progress.todos.len(), 2);
        assert_eq!(progress.todos[0].status, TodoStatus::Completed);
        assert_eq!(progress.todos[1].status, TodoStatus::InProgress);
    }
}
