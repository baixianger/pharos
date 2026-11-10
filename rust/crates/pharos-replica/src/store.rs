//! SQLite replica store applying `pharos-store-schema` PHASE0_DDL.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use pharos_store_schema::{MIGRATIONS, SCHEMA_VERSION, paths, tables};
use rusqlite::{Connection, OptionalExtension, params};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ReplicaStoreError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("schema: {0}")]
    Schema(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustGroupRow {
    pub id: String,
    pub membership_epoch: i64,
    pub meta_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceIdentityRow {
    pub device_id: String,
    pub public_key_pem: String,
    pub meta_json: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MessageRow {
    pub id: String,
    pub room_id: String,
    pub author_member_id: Option<String>,
    pub author_nick: String,
    pub text: String,
    pub ts: f64,
    pub reply_to_message_id: Option<String>,
    pub target_member_ids_json: String,
    pub attachments_json: String,
}

pub struct ReplicaStore {
    conn: Connection,
    path: PathBuf,
}

impl ReplicaStore {
    /// Open `{data_dir}/mesh/replica.sqlite3`, creating dirs and applying migrations.
    pub fn open(data_dir: &Path) -> Result<Self, ReplicaStoreError> {
        let mesh_dir = data_dir.join(paths::MESH_DIR);
        std::fs::create_dir_all(&mesh_dir)?;
        let path = mesh_dir.join(paths::REPLICA_DB);
        let conn = Connection::open(&path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        let mut store = Self { conn, path };
        store.migrate()?;
        Ok(store)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn migrate(&mut self) -> Result<(), ReplicaStoreError> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                applied_at TEXT NOT NULL
            );",
        )?;
        let current: i64 = self
            .conn
            .query_row(
                "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);
        for migration in MIGRATIONS {
            if (migration.version as i64) <= current {
                continue;
            }
            let tx = self.conn.unchecked_transaction()?;
            tx.execute_batch(migration.sql)?;
            let applied_at = rfc3339_now();
            tx.execute(
                "INSERT INTO schema_migrations(version, name, applied_at) VALUES (?1, ?2, ?3)",
                params![migration.version as i64, migration.name, applied_at],
            )?;
            tx.commit()?;
        }
        let applied: i64 = self.conn.query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |r| r.get(0),
        )?;
        if applied != SCHEMA_VERSION as i64 {
            return Err(ReplicaStoreError::Schema(format!(
                "expected schema {SCHEMA_VERSION}, got {applied}"
            )));
        }
        Ok(())
    }

    pub fn upsert_trust_group(
        &self,
        id: &str,
        membership_epoch: i64,
        meta_json: &str,
    ) -> Result<(), ReplicaStoreError> {
        self.conn.execute(
            &format!(
                "INSERT INTO {}(id, membership_epoch, meta_json) VALUES (?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET membership_epoch=excluded.membership_epoch,
                 meta_json=excluded.meta_json",
                tables::TRUST_GROUPS
            ),
            params![id, membership_epoch, meta_json],
        )?;
        Ok(())
    }

    pub fn get_trust_group(&self, id: &str) -> Result<Option<TrustGroupRow>, ReplicaStoreError> {
        let row = self
            .conn
            .query_row(
                &format!(
                    "SELECT id, membership_epoch, meta_json FROM {} WHERE id = ?1",
                    tables::TRUST_GROUPS
                ),
                params![id],
                |r| {
                    Ok(TrustGroupRow {
                        id: r.get(0)?,
                        membership_epoch: r.get(1)?,
                        meta_json: r.get(2)?,
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    pub fn upsert_device_identity(
        &self,
        device_id: &str,
        public_key_pem: &str,
        meta_json: &str,
    ) -> Result<(), ReplicaStoreError> {
        self.conn.execute(
            &format!(
                "INSERT INTO {}(device_id, public_key_pem, meta_json) VALUES (?1, ?2, ?3)
                 ON CONFLICT(device_id) DO UPDATE SET public_key_pem=excluded.public_key_pem,
                 meta_json=excluded.meta_json",
                tables::DEVICE_IDENTITY
            ),
            params![device_id, public_key_pem, meta_json],
        )?;
        Ok(())
    }

    pub fn list_device_identities(&self) -> Result<Vec<DeviceIdentityRow>, ReplicaStoreError> {
        let mut stmt = self.conn.prepare(&format!(
            "SELECT device_id, public_key_pem, meta_json FROM {} ORDER BY device_id",
            tables::DEVICE_IDENTITY
        ))?;
        let rows = stmt
            .query_map([], |r| {
                Ok(DeviceIdentityRow {
                    device_id: r.get(0)?,
                    public_key_pem: r.get(1)?,
                    meta_json: r.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn upsert_message(&self, msg: &MessageRow) -> Result<(), ReplicaStoreError> {
        self.conn.execute(
            &format!(
                "INSERT INTO {}(
                    id, room_id, author_member_id, author_nick, text, ts,
                    reply_to_message_id, target_member_ids_json, attachments_json
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
                 ON CONFLICT(id) DO UPDATE SET
                    text=excluded.text,
                    ts=excluded.ts,
                    reply_to_message_id=excluded.reply_to_message_id,
                    target_member_ids_json=excluded.target_member_ids_json,
                    attachments_json=excluded.attachments_json",
                tables::MESSAGES
            ),
            params![
                msg.id,
                msg.room_id,
                msg.author_member_id,
                msg.author_nick,
                msg.text,
                msg.ts,
                msg.reply_to_message_id,
                msg.target_member_ids_json,
                msg.attachments_json,
            ],
        )?;
        Ok(())
    }

    pub fn messages_since(
        &self,
        room_id: Option<&str>,
        since_ts: f64,
        limit: i64,
    ) -> Result<Vec<MessageRow>, ReplicaStoreError> {
        let mut rows = Vec::new();
        if let Some(room) = room_id {
            let mut stmt = self.conn.prepare(&format!(
                "SELECT id, room_id, author_member_id, author_nick, text, ts,
                        reply_to_message_id, target_member_ids_json, attachments_json
                 FROM {} WHERE room_id = ?1 AND ts > ?2 ORDER BY ts ASC LIMIT ?3",
                tables::MESSAGES
            ))?;
            let mapped = stmt.query_map(params![room, since_ts, limit], map_message)?;
            for row in mapped {
                rows.push(row?);
            }
        } else {
            let mut stmt = self.conn.prepare(&format!(
                "SELECT id, room_id, author_member_id, author_nick, text, ts,
                        reply_to_message_id, target_member_ids_json, attachments_json
                 FROM {} WHERE ts > ?1 ORDER BY ts ASC LIMIT ?2",
                tables::MESSAGES
            ))?;
            let mapped = stmt.query_map(params![since_ts, limit], map_message)?;
            for row in mapped {
                rows.push(row?);
            }
        }
        Ok(rows)
    }

    pub fn message_count(&self) -> Result<i64, ReplicaStoreError> {
        let count = self.conn.query_row(
            &format!("SELECT COUNT(*) FROM {}", tables::MESSAGES),
            [],
            |r| r.get(0),
        )?;
        Ok(count)
    }
}

fn map_message(r: &rusqlite::Row<'_>) -> rusqlite::Result<MessageRow> {
    Ok(MessageRow {
        id: r.get(0)?,
        room_id: r.get(1)?,
        author_member_id: r.get(2)?,
        author_nick: r.get(3)?,
        text: r.get(4)?,
        ts: r.get(5)?,
        reply_to_message_id: r.get(6)?,
        target_member_ids_json: r.get(7)?,
        attachments_json: r.get(8)?,
    })
}

fn rfc3339_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Sufficient for migrations bookkeeping; not a signing clock.
    format!("{secs}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn opens_and_migrates_phase0() {
        let dir = tempdir().unwrap();
        let store = ReplicaStore::open(dir.path()).unwrap();
        assert!(store.path().ends_with("mesh/replica.sqlite3"));
        store
            .upsert_trust_group("tg-1", 1, "{\"roles\":[\"controller\"]}")
            .unwrap();
        let tg = store.get_trust_group("tg-1").unwrap().unwrap();
        assert_eq!(tg.membership_epoch, 1);
        store.upsert_device_identity("dev-1", "pem", "{}").unwrap();
        assert_eq!(store.list_device_identities().unwrap().len(), 1);
    }

    #[test]
    fn message_sync_helpers() {
        let dir = tempdir().unwrap();
        let store = ReplicaStore::open(dir.path()).unwrap();
        store
            .upsert_message(&MessageRow {
                id: "m1".into(),
                room_id: "r1".into(),
                author_member_id: Some("a".into()),
                author_nick: "alice".into(),
                text: "hi".into(),
                ts: 10.0,
                reply_to_message_id: None,
                target_member_ids_json: "[]".into(),
                attachments_json: "[]".into(),
            })
            .unwrap();
        let got = store.messages_since(Some("r1"), 0.0, 10).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].text, "hi");
    }
}
