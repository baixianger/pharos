//! Durable session attachments store.
//!
//! Layout under the Host data dir (see `docs/2026-11-11_web-endpoints-api.md`):
//!
//! ```text
//! <data-dir>/attachments/index.json
//! {"version":1,"attachments":[{attachmentId,sessionId,filename,contentType,
//!                              sizeBytes,sha256,createdAt}]}
//! <data-dir>/attachments/<attachmentId>   # raw bytes, id = 32 lowercase hex
//! ```
//!
//! Guarantees:
//! - both the index and every blob are written atomically (temp+fsync+rename).
//! - the index is the source of truth: a metadata row whose blob is missing is a
//!   [`StoreError::Corrupt`] error, never an empty attachment.
//! - a corrupt / truncated / wrong-version index is a hard error on open.
//! - validation lives here (filename/content-type/size) so every implementation
//!   and the HTTP layer share one rule set; failures are [`StoreError::Invalid`]
//!   (HTTP 400). Base64 decoding is [`super::persist::decode_base64`] (strict,
//!   dependency-free).
//! - uploads arrive as already-decoded bytes ([`UploadedAttachment`]): the HTTP
//!   layer enforces the encoded-size guard before decoding.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::persist::{
    StoreError, now_rfc3339, read_blob, read_versioned_store, sha256_hex, write_bytes_atomic,
    write_json_atomic,
};

/// Directory (inside the Host data dir) holding `index.json` + raw blobs.
pub const ATTACHMENTS_DIR: &str = "attachments";
/// Index file name inside [`ATTACHMENTS_DIR`].
pub const ATTACHMENTS_INDEX_FILE: &str = "index.json";
/// On-disk index envelope version. Bump on incompatible layout changes.
pub const ATTACHMENTS_INDEX_VERSION: u32 = 1;

/// Attachment ids are exactly 32 lowercase hex characters.
pub const ATTACHMENT_ID_LEN: usize = 32;
/// Maximum decoded attachment size (10 MiB, per contract).
pub const MAX_ATTACHMENT_BYTES: usize = 10 * 1024 * 1024;
/// Maximum filename length (contract).
pub const MAX_FILENAME_LEN: usize = 255;

/// Content types accepted by `POST /sessions/{id}/attachments`.
pub const ALLOWED_CONTENT_TYPES: &[&str] = &[
    "text/plain",
    "text/markdown",
    "text/csv",
    "application/json",
    "image/png",
    "image/jpeg",
    "application/pdf",
];

static ATTACHMENT_COUNTER: AtomicU64 = AtomicU64::new(0);

/// One already-decoded upload handed to [`AttachmentService::create`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadedAttachment {
    pub filename: String,
    pub content_type: String,
    pub bytes: Vec<u8>,
}

/// Wire metadata for one stored attachment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentMetadata {
    pub attachment_id: String,
    pub session_id: String,
    pub filename: String,
    pub content_type: String,
    pub size_bytes: u64,
    pub sha256: String,
    /// RFC3339 creation timestamp.
    pub created_at: String,
}

/// Durable attachment surface mounted on [`crate::state::AppState`].
#[async_trait]
pub trait AttachmentService: Send + Sync {
    /// Validate + store one upload for `session_id`. Session existence is the
    /// HTTP layer's concern; this store records whatever session id it is given.
    async fn create(
        &self,
        session_id: &str,
        upload: UploadedAttachment,
    ) -> Result<AttachmentMetadata, StoreError>;

    /// Metadata of one attachment, `None` when unknown.
    async fn get(&self, attachment_id: &str) -> Result<Option<AttachmentMetadata>, StoreError>;

    /// Raw bytes of one attachment, `None` when unknown.
    async fn read(&self, attachment_id: &str) -> Result<Option<Vec<u8>>, StoreError>;

    /// Metadata of every attachment of a session, oldest first.
    async fn list_for_session(
        &self,
        session_id: &str,
    ) -> Result<Vec<AttachmentMetadata>, StoreError>;
}

// ---------------------------------------------------------------------------
// validation
// ---------------------------------------------------------------------------

fn invalid(message: impl Into<String>) -> StoreError {
    StoreError::invalid(message)
}

/// Validate an attachment filename: non-empty, ≤255 chars, no `/` or `\`, no
/// control characters.
pub fn validate_filename(filename: &str) -> Result<(), StoreError> {
    if filename.trim().is_empty() {
        return Err(invalid("filename must not be empty"));
    }
    if filename.chars().count() > MAX_FILENAME_LEN {
        return Err(invalid(format!(
            "filename must be at most {MAX_FILENAME_LEN} characters"
        )));
    }
    if filename.contains(['/', '\\']) {
        return Err(invalid("filename must not contain path separators"));
    }
    if filename.chars().any(char::is_control) {
        return Err(invalid("filename must not contain control characters"));
    }
    Ok(())
}

/// Validate an attachment content type against the contract allowlist.
pub fn validate_content_type(content_type: &str) -> Result<(), StoreError> {
    if ALLOWED_CONTENT_TYPES.contains(&content_type) {
        Ok(())
    } else {
        Err(invalid(format!(
            "contentType {content_type:?} is not one of {ALLOWED_CONTENT_TYPES:?}"
        )))
    }
}

/// Validate a decoded upload. Returns the bytes to store after checking the
/// filename, content type and the `1..=10 MiB` decoded-size window.
pub fn validate_upload(upload: &UploadedAttachment) -> Result<(), StoreError> {
    validate_filename(&upload.filename)?;
    validate_content_type(&upload.content_type)?;
    if upload.bytes.is_empty() {
        return Err(invalid("attachment payload must not be empty"));
    }
    if upload.bytes.len() > MAX_ATTACHMENT_BYTES {
        return Err(invalid(format!(
            "attachment payload must be at most {MAX_ATTACHMENT_BYTES} bytes"
        )));
    }
    Ok(())
}

fn generate_attachment_id(session_id: &str, filename: &str, sha256: &str, size: usize) -> String {
    let counter = ATTACHMENT_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let seed = format!(
        "{session_id}\0{filename}\0{sha256}\0{size}\0{}\0{counter}\0{nanos}",
        std::process::id()
    );
    sha256_hex(seed.as_bytes())[..ATTACHMENT_ID_LEN].to_string()
}

fn validate_attachment_id(attachment_id: &str) -> Result<(), StoreError> {
    let valid = attachment_id.len() == ATTACHMENT_ID_LEN
        && attachment_id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
    if valid {
        Ok(())
    } else {
        Err(invalid(format!(
            "attachmentId must be {ATTACHMENT_ID_LEN} lowercase hex characters"
        )))
    }
}

fn build_metadata(
    session_id: &str,
    upload: &UploadedAttachment,
) -> Result<AttachmentMetadata, StoreError> {
    if session_id.trim().is_empty() {
        return Err(invalid("sessionId must not be empty"));
    }
    validate_upload(upload)?;
    let sha256 = sha256_hex(&upload.bytes);
    Ok(AttachmentMetadata {
        attachment_id: generate_attachment_id(
            session_id,
            &upload.filename,
            &sha256,
            upload.bytes.len(),
        ),
        session_id: session_id.to_string(),
        filename: upload.filename.clone(),
        content_type: upload.content_type.clone(),
        size_bytes: upload.bytes.len() as u64,
        sha256,
        created_at: now_rfc3339(),
    })
}

fn sorted_session(
    metadata: &BTreeMap<String, AttachmentMetadata>,
    session_id: &str,
) -> Vec<AttachmentMetadata> {
    let mut items: Vec<AttachmentMetadata> = metadata
        .values()
        .filter(|item| item.session_id == session_id)
        .cloned()
        .collect();
    items.sort_by(|left, right| {
        left.created_at
            .cmp(&right.created_at)
            .then_with(|| left.attachment_id.cmp(&right.attachment_id))
    });
    items
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AttachmentsFile {
    version: u32,
    attachments: Vec<AttachmentMetadata>,
}

fn load_index(path: &Path) -> Result<BTreeMap<String, AttachmentMetadata>, StoreError> {
    let Some(file) =
        read_versioned_store::<AttachmentsFile>(path, ATTACHMENTS_INDEX_VERSION, |file| {
            file.version
        })?
    else {
        return Ok(BTreeMap::new());
    };
    let mut index = BTreeMap::new();
    for metadata in file.attachments {
        validate_attachment_id(&metadata.attachment_id)?;
        if index
            .insert(metadata.attachment_id.clone(), metadata)
            .is_some()
        {
            return Err(StoreError::corrupt(path, "duplicate attachmentId in index"));
        }
    }
    Ok(index)
}

fn index_file(index: &BTreeMap<String, AttachmentMetadata>) -> AttachmentsFile {
    AttachmentsFile {
        version: ATTACHMENTS_INDEX_VERSION,
        attachments: index.values().cloned().collect(),
    }
}

/// In-memory store (default for tests / fake mode).
#[derive(Debug, Default)]
pub struct InMemoryAttachmentService {
    state: Mutex<InMemoryAttachmentState>,
}

#[derive(Debug, Default)]
struct InMemoryAttachmentState {
    index: BTreeMap<String, AttachmentMetadata>,
    blobs: BTreeMap<String, Vec<u8>>,
}

impl InMemoryAttachmentService {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl AttachmentService for InMemoryAttachmentService {
    async fn create(
        &self,
        session_id: &str,
        upload: UploadedAttachment,
    ) -> Result<AttachmentMetadata, StoreError> {
        let metadata = build_metadata(session_id, &upload)?;
        let mut state = lock(&self.state);
        state
            .blobs
            .insert(metadata.attachment_id.clone(), upload.bytes);
        state
            .index
            .insert(metadata.attachment_id.clone(), metadata.clone());
        Ok(metadata)
    }

    async fn get(&self, attachment_id: &str) -> Result<Option<AttachmentMetadata>, StoreError> {
        let state = lock(&self.state);
        Ok(state.index.get(attachment_id).cloned())
    }

    async fn read(&self, attachment_id: &str) -> Result<Option<Vec<u8>>, StoreError> {
        let state = lock(&self.state);
        match state.index.get(attachment_id) {
            None => Ok(None),
            Some(_) => Ok(state.blobs.get(attachment_id).cloned()),
        }
    }

    async fn list_for_session(
        &self,
        session_id: &str,
    ) -> Result<Vec<AttachmentMetadata>, StoreError> {
        let state = lock(&self.state);
        Ok(sorted_session(&state.index, session_id))
    }
}

/// File-backed store: index + blobs survive restarts.
#[derive(Debug)]
pub struct FileAttachmentService {
    index_path: PathBuf,
    blobs_dir: PathBuf,
    index: Mutex<BTreeMap<String, AttachmentMetadata>>,
}

impl FileAttachmentService {
    /// Open the store at `<attachments-dir>/index.json` (created on first write).
    pub fn open(index_path: impl Into<PathBuf>) -> Result<Self, StoreError> {
        let index_path = index_path.into();
        let blobs_dir = index_path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let index = load_index(&index_path)?;
        Ok(Self {
            index_path,
            blobs_dir,
            index: Mutex::new(index),
        })
    }

    /// Open the store inside a data dir (`<data-dir>/attachments/index.json`).
    pub fn open_in(data_dir: impl AsRef<Path>) -> Result<Self, StoreError> {
        Self::open(
            data_dir
                .as_ref()
                .join(ATTACHMENTS_DIR)
                .join(ATTACHMENTS_INDEX_FILE),
        )
    }

    pub fn index_path(&self) -> &Path {
        &self.index_path
    }

    pub fn blobs_dir(&self) -> &Path {
        &self.blobs_dir
    }

    fn blob_path(&self, attachment_id: &str) -> PathBuf {
        self.blobs_dir.join(attachment_id)
    }

    fn persist(&self, index: &BTreeMap<String, AttachmentMetadata>) -> Result<(), StoreError> {
        write_json_atomic(&self.index_path, &index_file(index))
    }
}

#[async_trait]
impl AttachmentService for FileAttachmentService {
    async fn create(
        &self,
        session_id: &str,
        upload: UploadedAttachment,
    ) -> Result<AttachmentMetadata, StoreError> {
        let metadata = build_metadata(session_id, &upload)?;
        let mut index = lock(&self.index);
        // Blob first: the index only ever references durable bytes.
        write_bytes_atomic(&self.blob_path(&metadata.attachment_id), &upload.bytes)?;
        index.insert(metadata.attachment_id.clone(), metadata.clone());
        if let Err(error) = self.persist(&index) {
            index.remove(&metadata.attachment_id);
            let _ = std::fs::remove_file(self.blob_path(&metadata.attachment_id));
            return Err(error);
        }
        Ok(metadata)
    }

    async fn get(&self, attachment_id: &str) -> Result<Option<AttachmentMetadata>, StoreError> {
        let index = lock(&self.index);
        Ok(index.get(attachment_id).cloned())
    }

    async fn read(&self, attachment_id: &str) -> Result<Option<Vec<u8>>, StoreError> {
        let index = lock(&self.index);
        if !index.contains_key(attachment_id) {
            return Ok(None);
        }
        match read_blob(&self.blob_path(attachment_id))? {
            Some(bytes) => Ok(Some(bytes)),
            None => Err(StoreError::corrupt(
                &self.blob_path(attachment_id),
                format!("attachment {attachment_id} is in the index but its blob is missing"),
            )),
        }
    }

    async fn list_for_session(
        &self,
        session_id: &str,
    ) -> Result<Vec<AttachmentMetadata>, StoreError> {
        let index = lock(&self.index);
        Ok(sorted_session(&index, session_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::persist::{decode_base64, encode_base64};

    fn upload(filename: &str, content_type: &str, bytes: &[u8]) -> UploadedAttachment {
        UploadedAttachment {
            filename: filename.to_string(),
            content_type: content_type.to_string(),
            bytes: bytes.to_vec(),
        }
    }

    #[test]
    fn upload_validation_rules() {
        assert!(validate_filename("notes.txt").is_ok());
        for bad in ["", "   ", "a/b.txt", "a\\b.txt", "bad\nname.txt"] {
            assert!(validate_filename(bad).is_err(), "{bad:?} must be rejected");
        }
        let long = "x".repeat(MAX_FILENAME_LEN + 1);
        assert!(validate_filename(&long).is_err());

        assert!(validate_content_type("text/plain").is_ok());
        assert!(validate_content_type("application/pdf").is_ok());
        for bad in ["", "text/html", "image/gif", "TEXT/PLAIN"] {
            assert!(
                validate_content_type(bad).is_err(),
                "{bad:?} must be rejected"
            );
        }

        assert!(validate_upload(&upload("a.txt", "text/plain", b"hello")).is_ok());
        assert!(validate_upload(&upload("a.txt", "text/plain", b"")).is_err());
        let oversized = vec![0u8; MAX_ATTACHMENT_BYTES + 1];
        assert!(validate_upload(&upload("a.bin", "text/plain", &oversized)).is_err());
    }

    #[test]
    fn uploaded_body_base64_decodes_to_validated_bytes() {
        let raw = decode_base64(&encode_base64(b"hello")).expect("round trip");
        assert_eq!(raw, b"hello".to_vec());
        assert!(decode_base64("not base64").is_err());
    }

    async fn exercise_service(service: &dyn AttachmentService) {
        let first = service
            .create("s1", upload("notes.txt", "text/plain", b"hello world"))
            .await
            .expect("create first");
        assert_eq!(first.session_id, "s1");
        assert_eq!(first.filename, "notes.txt");
        assert_eq!(first.content_type, "text/plain");
        assert_eq!(first.size_bytes, 11);
        assert_eq!(first.sha256, sha256_hex(b"hello world"));
        assert_eq!(first.attachment_id.len(), ATTACHMENT_ID_LEN);
        assert!(
            first
                .attachment_id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "id must be lowercase hex: {}",
            first.attachment_id
        );
        assert!(first.created_at.ends_with('Z'));

        let second = service
            .create("s1", upload("data.json", "application/json", b"{}"))
            .await
            .expect("create second");
        service
            .create("s2", upload("other.txt", "text/plain", b"other"))
            .await
            .expect("create other session");

        assert_eq!(
            service
                .get(&first.attachment_id)
                .await
                .expect("get")
                .expect("present"),
            first
        );
        assert!(service.get("0000").await.expect("unknown").is_none());
        assert_eq!(
            service.read(&first.attachment_id).await.expect("read"),
            Some(b"hello world".to_vec())
        );
        assert!(service.read("0000").await.expect("unknown").is_none());

        let session_list = service.list_for_session("s1").await.expect("list");
        assert_eq!(session_list.len(), 2);
        let ids: Vec<&str> = session_list
            .iter()
            .map(|item| item.attachment_id.as_str())
            .collect();
        assert!(ids.contains(&first.attachment_id.as_str()));
        assert!(ids.contains(&second.attachment_id.as_str()));
        assert_eq!(service.list_for_session("s2").await.expect("list").len(), 1);
        assert!(
            service
                .list_for_session("missing")
                .await
                .expect("list")
                .is_empty()
        );
    }

    #[tokio::test]
    async fn in_memory_store_round_trips() {
        let service = InMemoryAttachmentService::new();
        exercise_service(&service).await;
    }

    #[tokio::test]
    async fn invalid_uploads_are_rejected_and_not_stored() {
        let service = InMemoryAttachmentService::new();
        for bad in [
            upload("", "text/plain", b"x"),
            upload("a.txt", "text/html", b"x"),
            upload("a.txt", "text/plain", b""),
        ] {
            let error = service.create("s1", bad).await.expect_err("invalid upload");
            assert!(matches!(error, StoreError::Invalid { .. }), "{error}");
        }
        assert!(
            service
                .list_for_session("s1")
                .await
                .expect("list")
                .is_empty()
        );
    }

    #[tokio::test]
    async fn file_store_survives_reopen_with_blobs() {
        let dir = tempfile::tempdir().expect("tempdir");
        let index_path = dir
            .path()
            .join(ATTACHMENTS_DIR)
            .join(ATTACHMENTS_INDEX_FILE);
        let metadata = {
            let service = FileAttachmentService::open(&index_path).expect("open");
            assert!(!index_path.exists(), "open must not write an empty index");
            service
                .create("s1", upload("notes.txt", "text/plain", b"persisted"))
                .await
                .expect("create")
        };
        assert!(index_path.is_file());
        let raw = std::fs::read_to_string(&index_path).expect("read index");
        let json: serde_json::Value = serde_json::from_str(&raw).expect("json");
        assert_eq!(json["version"], ATTACHMENTS_INDEX_VERSION);
        assert_eq!(json["attachments"].as_array().expect("array").len(), 1);
        assert_eq!(
            json["attachments"][0]["attachmentId"],
            metadata.attachment_id
        );
        let blob_path = dir
            .path()
            .join(ATTACHMENTS_DIR)
            .join(&metadata.attachment_id);
        assert_eq!(
            std::fs::read(&blob_path).expect("blob"),
            b"persisted".to_vec()
        );

        let reopened = FileAttachmentService::open(&index_path).expect("reopen");
        assert_eq!(
            reopened
                .get(&metadata.attachment_id)
                .await
                .expect("get")
                .expect("present"),
            metadata
        );
        assert_eq!(
            reopened.read(&metadata.attachment_id).await.expect("read"),
            Some(b"persisted".to_vec())
        );
        assert_eq!(
            reopened.list_for_session("s1").await.expect("list").len(),
            1
        );
    }

    #[test]
    fn corrupt_index_is_a_hard_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let index_path = dir.path().join("index.json");
        std::fs::write(&index_path, b"{ not json").expect("write corrupt");
        assert!(matches!(
            FileAttachmentService::open(&index_path),
            Err(StoreError::Corrupt { .. })
        ));
        assert_eq!(
            std::fs::read(&index_path).expect("read"),
            b"{ not json".to_vec()
        );
        std::fs::write(&index_path, br#"{"version":3,"attachments":[]}"#).expect("write version");
        assert!(matches!(
            FileAttachmentService::open(&index_path),
            Err(StoreError::Corrupt { .. })
        ));
    }

    #[tokio::test]
    async fn missing_blob_for_indexed_attachment_is_corrupt() {
        let dir = tempfile::tempdir().expect("tempdir");
        let index_path = dir.path().join("attachments").join("index.json");
        let metadata = {
            let service = FileAttachmentService::open(&index_path).expect("open");
            service
                .create("s1", upload("notes.txt", "text/plain", b"gone"))
                .await
                .expect("create")
        };
        std::fs::remove_file(dir.path().join("attachments").join(&metadata.attachment_id))
            .expect("remove blob");
        let reopened = FileAttachmentService::open(&index_path).expect("reopen");
        let error = reopened
            .read(&metadata.attachment_id)
            .await
            .expect_err("missing blob must be corrupt");
        assert!(matches!(error, StoreError::Corrupt { .. }), "{error}");
    }

    #[tokio::test]
    async fn two_attachments_with_same_bytes_get_distinct_ids() {
        let service = InMemoryAttachmentService::new();
        let first = service
            .create("s1", upload("a.txt", "text/plain", b"same"))
            .await
            .expect("first");
        let second = service
            .create("s1", upload("a.txt", "text/plain", b"same"))
            .await
            .expect("second");
        assert_ne!(first.attachment_id, second.attachment_id);
        assert_eq!(first.sha256, second.sha256);
    }
}
