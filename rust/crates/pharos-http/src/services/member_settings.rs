//! Durable per-member settings + avatar store.
//!
//! Layout under the Host data dir (see `docs/2026-11-11_web-endpoints-api.md`):
//!
//! ```text
//! <data-dir>/member-settings.json
//! {"version":1,"members":[{memberId,displayName?,model?,mode?,avatarShape?,
//!                          avatarColor?,avatar?,updatedAt?}]}
//! <data-dir>/avatars/<sha256>.<png|jpg>   # raw avatar bytes
//! ```
//!
//! Guarantees:
//! - settings and avatar blobs are written atomically (temp+fsync+rename).
//! - avatars are content-addressed by SHA-256; replacing/deleting a member's
//!   avatar only removes a blob when no other member still references it.
//! - a corrupt / truncated / wrong-version settings file is a hard error on
//!   open, never a silent reset.
//! - validation lives here (member id, patch values, avatar content type/size)
//!   so every implementation and the HTTP layer share one rule set; failures
//!   are [`StoreError::Invalid`] (HTTP 400).
//! - `get` never invents state: a valid-but-unconfigured member returns the
//!   empty settings view (`{memberId, avatar:null, …}`) without touching disk.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::bindings::ThreadBindingView;
use super::persist::{
    StoreError, now_rfc3339, read_blob, read_versioned_store, sha256_hex, write_bytes_atomic,
    write_json_atomic,
};
use super::session::SESSION_MODES;

/// Settings file name inside the Host data dir.
pub const MEMBER_SETTINGS_FILE: &str = "member-settings.json";
/// Avatars directory inside the Host data dir.
pub const AVATARS_DIR: &str = "avatars";
/// On-disk settings envelope version. Bump on incompatible layout changes.
pub const MEMBER_SETTINGS_STORE_VERSION: u32 = 1;

/// Maximum member id length (contract).
pub const MAX_MEMBER_ID_LEN: usize = 64;
/// Maximum display name length (contract).
pub const MAX_DISPLAY_NAME_LEN: usize = 80;
/// Maximum member model length (contract).
pub const MAX_MODEL_LEN: usize = 120;
/// Maximum avatar shape / color token length (contract).
pub const MAX_AVATAR_STYLE_LEN: usize = 32;
/// Maximum decoded avatar size (512 KiB, per contract).
pub const MAX_AVATAR_BYTES: usize = 512 * 1024;

/// Avatar content types accepted by `PUT /members/{id}/avatar`.
pub const AVATAR_CONTENT_TYPES: &[&str] = &["image/png", "image/jpeg"];

/// One avatar as persisted in the settings view (bytes live in `avatars/`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemberAvatarView {
    /// Content address: the SHA-256 of the bytes (also the file stem).
    pub avatar_id: String,
    pub content_type: String,
    pub size_bytes: u64,
    pub sha256: String,
    /// RFC3339 upload timestamp.
    pub updated_at: String,
}

impl MemberAvatarView {
    /// File extension used by the stored blob (`png` / `jpg`).
    pub fn file_extension(&self) -> &'static str {
        match self.content_type.as_str() {
            "image/jpeg" => "jpg",
            _ => "png",
        }
    }
}

/// Durable member settings view (wire + persisted shape).
///
/// `bindings` is composed by the HTTP layer from
/// [`super::bindings::ThreadBindingService::for_member`]; the store itself
/// always returns an empty list.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemberSettingsView {
    pub member_id: String,
    pub display_name: Option<String>,
    pub model: Option<String>,
    pub mode: Option<String>,
    pub avatar_shape: Option<String>,
    pub avatar_color: Option<String>,
    pub avatar: Option<MemberAvatarView>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub bindings: Vec<ThreadBindingView>,
    pub updated_at: Option<String>,
}

impl MemberSettingsView {
    /// Empty view for a valid but never-configured member.
    pub fn empty(member_id: &str) -> Self {
        Self {
            member_id: member_id.to_string(),
            ..Self::default()
        }
    }
}

/// `PATCH /api/v1/members/{memberId}` body (all fields optional).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemberSettingsPatch {
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub avatar_shape: Option<String>,
    #[serde(default)]
    pub avatar_color: Option<String>,
}

impl MemberSettingsPatch {
    pub fn is_empty(&self) -> bool {
        self.display_name.is_none()
            && self.model.is_none()
            && self.mode.is_none()
            && self.avatar_shape.is_none()
            && self.avatar_color.is_none()
    }

    /// Validate every provided field without touching the store.
    pub fn validate(&self) -> Result<(), StoreError> {
        if self.is_empty() {
            return Err(StoreError::invalid(
                "member settings patch must set at least one field",
            ));
        }
        if let Some(value) = &self.display_name {
            validate_text_field(value, MAX_DISPLAY_NAME_LEN, "displayName")?;
        }
        if let Some(value) = &self.model {
            validate_text_field(value, MAX_MODEL_LEN, "model")?;
        }
        if let Some(value) = &self.mode
            && !SESSION_MODES.contains(&value.trim())
        {
            return Err(StoreError::invalid(format!(
                "mode must be one of {SESSION_MODES:?}, got {value:?}"
            )));
        }
        if let Some(value) = &self.avatar_shape {
            validate_text_field(value, MAX_AVATAR_STYLE_LEN, "avatarShape")?;
        }
        if let Some(value) = &self.avatar_color {
            validate_text_field(value, MAX_AVATAR_STYLE_LEN, "avatarColor")?;
        }
        Ok(())
    }
}

fn validate_text_field(value: &str, max_len: usize, field: &str) -> Result<(), StoreError> {
    if value.trim().is_empty() {
        return Err(StoreError::invalid(format!("{field} must not be blank")));
    }
    if value.chars().count() > max_len {
        return Err(StoreError::invalid(format!(
            "{field} must be at most {max_len} characters"
        )));
    }
    Ok(())
}

/// Validate a member id: non-empty, ≤64 chars, no control characters, no `/`.
pub fn validate_member_id(member_id: &str) -> Result<(), StoreError> {
    if member_id.trim().is_empty() {
        return Err(StoreError::invalid("memberId must not be empty"));
    }
    if member_id.chars().count() > MAX_MEMBER_ID_LEN {
        return Err(StoreError::invalid(format!(
            "memberId must be at most {MAX_MEMBER_ID_LEN} characters"
        )));
    }
    if member_id.contains('/') {
        return Err(StoreError::invalid("memberId must not contain '/'"));
    }
    if member_id.chars().any(char::is_control) {
        return Err(StoreError::invalid(
            "memberId must not contain control characters",
        ));
    }
    Ok(())
}

/// One avatar blob read back for `GET /api/v1/members/{id}/avatar`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredAvatar {
    pub content_type: String,
    pub bytes: Vec<u8>,
}

fn validate_avatar_upload(content_type: &str, bytes: &[u8]) -> Result<(), StoreError> {
    if !AVATAR_CONTENT_TYPES.contains(&content_type) {
        return Err(StoreError::invalid(format!(
            "avatar contentType {content_type:?} is not one of {AVATAR_CONTENT_TYPES:?}"
        )));
    }
    if bytes.is_empty() {
        return Err(StoreError::invalid("avatar payload must not be empty"));
    }
    if bytes.len() > MAX_AVATAR_BYTES {
        return Err(StoreError::invalid(format!(
            "avatar payload must be at most {MAX_AVATAR_BYTES} bytes"
        )));
    }
    Ok(())
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MembersFile {
    version: u32,
    members: Vec<MemberSettingsView>,
}

fn load_members(path: &Path) -> Result<BTreeMap<String, MemberSettingsView>, StoreError> {
    let Some(file) =
        read_versioned_store::<MembersFile>(path, MEMBER_SETTINGS_STORE_VERSION, |file| {
            file.version
        })?
    else {
        return Ok(BTreeMap::new());
    };
    let mut members = BTreeMap::new();
    for mut member in file.members {
        validate_member_id(&member.member_id)?;
        // Bindings are composed from the bindings store on read; never persisted.
        member.bindings = Vec::new();
        if members.insert(member.member_id.clone(), member).is_some() {
            return Err(StoreError::corrupt(path, "duplicate memberId in settings"));
        }
    }
    Ok(members)
}

fn members_file(members: &BTreeMap<String, MemberSettingsView>) -> MembersFile {
    MembersFile {
        version: MEMBER_SETTINGS_STORE_VERSION,
        members: members.values().cloned().collect(),
    }
}

/// In-memory store (default for tests / fake mode).
#[derive(Debug, Default)]
pub struct InMemoryMemberSettingsService {
    state: Mutex<InMemoryMemberState>,
}

#[derive(Debug, Default)]
struct InMemoryMemberState {
    members: BTreeMap<String, MemberSettingsView>,
    avatars: BTreeMap<String, StoredAvatar>,
}

impl InMemoryMemberSettingsService {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl MemberSettingsService for InMemoryMemberSettingsService {
    async fn get(&self, member_id: &str) -> Result<MemberSettingsView, StoreError> {
        validate_member_id(member_id)?;
        let state = lock(&self.state);
        Ok(state
            .members
            .get(member_id)
            .cloned()
            .map(|mut view| {
                view.bindings = Vec::new();
                view
            })
            .unwrap_or_else(|| MemberSettingsView::empty(member_id)))
    }

    async fn patch(
        &self,
        member_id: &str,
        patch: MemberSettingsPatch,
    ) -> Result<MemberSettingsView, StoreError> {
        validate_member_id(member_id)?;
        patch.validate()?;
        let mut state = lock(&self.state);
        let view = state
            .members
            .entry(member_id.to_string())
            .or_insert_with(|| MemberSettingsView::empty(member_id));
        apply_patch(view, &patch);
        view.bindings = Vec::new();
        Ok(view.clone())
    }

    async fn put_avatar(
        &self,
        member_id: &str,
        content_type: &str,
        bytes: Vec<u8>,
    ) -> Result<MemberSettingsView, StoreError> {
        validate_member_id(member_id)?;
        validate_avatar_upload(content_type, &bytes)?;
        let sha256 = sha256_hex(&bytes);
        let mut state = lock(&self.state);
        let view = state
            .members
            .entry(member_id.to_string())
            .or_insert_with(|| MemberSettingsView::empty(member_id));
        let now = now_rfc3339();
        view.avatar = Some(MemberAvatarView {
            avatar_id: sha256.clone(),
            content_type: content_type.to_string(),
            size_bytes: bytes.len() as u64,
            sha256: sha256.clone(),
            updated_at: now.clone(),
        });
        view.updated_at = Some(now);
        view.bindings = Vec::new();
        let stored_view = view.clone();
        state.avatars.insert(
            sha256,
            StoredAvatar {
                content_type: content_type.to_string(),
                bytes,
            },
        );
        Ok(stored_view)
    }

    async fn get_avatar(&self, member_id: &str) -> Result<Option<StoredAvatar>, StoreError> {
        validate_member_id(member_id)?;
        let state = lock(&self.state);
        let Some(view) = state.members.get(member_id) else {
            return Ok(None);
        };
        let Some(avatar) = &view.avatar else {
            return Ok(None);
        };
        Ok(state.avatars.get(&avatar.avatar_id).cloned())
    }

    async fn delete_avatar(&self, member_id: &str) -> Result<bool, StoreError> {
        validate_member_id(member_id)?;
        let mut state = lock(&self.state);
        let Some(view) = state.members.get_mut(member_id) else {
            return Ok(false);
        };
        let Some(avatar) = view.avatar.take() else {
            return Ok(false);
        };
        view.updated_at = Some(now_rfc3339());
        state.avatars.remove(&avatar.avatar_id);
        Ok(true)
    }
}

/// File-backed store: settings + avatars survive restarts.
#[derive(Debug)]
pub struct FileMemberSettingsService {
    path: PathBuf,
    avatars_dir: PathBuf,
    members: Mutex<BTreeMap<String, MemberSettingsView>>,
}

impl FileMemberSettingsService {
    /// Open the settings file at `path`; avatar blobs live in `avatars_dir`
    /// (`<data-dir>/avatars`). A corrupt settings file is a hard error.
    pub fn open(
        path: impl Into<PathBuf>,
        avatars_dir: impl Into<PathBuf>,
    ) -> Result<Self, StoreError> {
        let path = path.into();
        let members = load_members(&path)?;
        Ok(Self {
            path,
            avatars_dir: avatars_dir.into(),
            members: Mutex::new(members),
        })
    }

    /// Open both stores inside a data dir.
    pub fn open_in(data_dir: impl AsRef<Path>) -> Result<Self, StoreError> {
        let data_dir = data_dir.as_ref();
        Self::open(
            data_dir.join(MEMBER_SETTINGS_FILE),
            data_dir.join(AVATARS_DIR),
        )
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn avatars_dir(&self) -> &Path {
        &self.avatars_dir
    }

    fn persist(&self, members: &BTreeMap<String, MemberSettingsView>) -> Result<(), StoreError> {
        write_json_atomic(&self.path, &members_file(members))
    }

    fn avatar_path(&self, avatar: &MemberAvatarView) -> PathBuf {
        self.avatars_dir
            .join(format!("{}.{}", avatar.sha256, avatar.file_extension()))
    }

    /// Remove a blob that is no longer referenced by any member (safe shared
    /// content-addressed storage).
    fn remove_avatar_blob_if_unreferenced(
        &self,
        members: &BTreeMap<String, MemberSettingsView>,
        avatar: &MemberAvatarView,
    ) {
        let still_referenced = members.values().any(|member| {
            member
                .avatar
                .as_ref()
                .is_some_and(|other| other.sha256 == avatar.sha256)
        });
        if !still_referenced {
            let _ = std::fs::remove_file(self.avatar_path(avatar));
        }
    }
}

#[async_trait]
impl MemberSettingsService for FileMemberSettingsService {
    async fn get(&self, member_id: &str) -> Result<MemberSettingsView, StoreError> {
        validate_member_id(member_id)?;
        let members = lock(&self.members);
        Ok(members
            .get(member_id)
            .cloned()
            .map(|mut view| {
                view.bindings = Vec::new();
                view
            })
            .unwrap_or_else(|| MemberSettingsView::empty(member_id)))
    }

    async fn patch(
        &self,
        member_id: &str,
        patch: MemberSettingsPatch,
    ) -> Result<MemberSettingsView, StoreError> {
        validate_member_id(member_id)?;
        patch.validate()?;
        let mut members = lock(&self.members);
        let previous = members
            .get(member_id)
            .cloned()
            .unwrap_or_else(|| MemberSettingsView::empty(member_id));
        let mut view = previous;
        apply_patch(&mut view, &patch);
        view.bindings = Vec::new();
        members.insert(member_id.to_string(), view.clone());
        self.persist(&members)?;
        Ok(view)
    }

    async fn put_avatar(
        &self,
        member_id: &str,
        content_type: &str,
        bytes: Vec<u8>,
    ) -> Result<MemberSettingsView, StoreError> {
        validate_member_id(member_id)?;
        validate_avatar_upload(content_type, &bytes)?;
        let sha256 = sha256_hex(&bytes);
        let now = now_rfc3339();
        let avatar = MemberAvatarView {
            avatar_id: sha256.clone(),
            content_type: content_type.to_string(),
            size_bytes: bytes.len() as u64,
            sha256,
            updated_at: now.clone(),
        };
        let mut members = lock(&self.members);
        let mut view = members
            .get(member_id)
            .cloned()
            .unwrap_or_else(|| MemberSettingsView::empty(member_id));
        let previous = view.avatar.take();
        view.avatar = Some(avatar.clone());
        view.updated_at = Some(now);
        view.bindings = Vec::new();
        write_bytes_atomic(&self.avatar_path(&avatar), &bytes)?;
        members.insert(member_id.to_string(), view.clone());
        if let Err(error) = self.persist(&members) {
            // Roll the in-memory record back to what is still on disk, then
            // report the failure (never a silent fake save).
            if let Some(previous) = previous {
                if let Some(stored) = members.get_mut(member_id) {
                    stored.avatar = Some(previous);
                }
            } else {
                members.remove(member_id);
            }
            return Err(error);
        }
        if let Some(previous) = previous
            && previous.sha256 != avatar.sha256
        {
            self.remove_avatar_blob_if_unreferenced(&members, &previous);
        }
        Ok(view)
    }

    async fn get_avatar(&self, member_id: &str) -> Result<Option<StoredAvatar>, StoreError> {
        validate_member_id(member_id)?;
        let avatar = {
            let members = lock(&self.members);
            let Some(view) = members.get(member_id) else {
                return Ok(None);
            };
            let Some(avatar) = &view.avatar else {
                return Ok(None);
            };
            avatar.clone()
        };
        let path = self.avatar_path(&avatar);
        match read_blob(&path)? {
            Some(bytes) => Ok(Some(StoredAvatar {
                content_type: avatar.content_type,
                bytes,
            })),
            None => Err(StoreError::corrupt(
                &path,
                format!(
                    "member {member_id} references avatar {} but its blob is missing",
                    avatar.sha256
                ),
            )),
        }
    }

    async fn delete_avatar(&self, member_id: &str) -> Result<bool, StoreError> {
        validate_member_id(member_id)?;
        let mut members = lock(&self.members);
        let Some(view) = members.get_mut(member_id) else {
            return Ok(false);
        };
        let Some(avatar) = view.avatar.take() else {
            return Ok(false);
        };
        view.updated_at = Some(now_rfc3339());
        view.bindings = Vec::new();
        self.persist(&members)?;
        self.remove_avatar_blob_if_unreferenced(&members, &avatar);
        Ok(true)
    }
}

fn apply_patch(view: &mut MemberSettingsView, patch: &MemberSettingsPatch) {
    if let Some(value) = &patch.display_name {
        view.display_name = Some(value.clone());
    }
    if let Some(value) = &patch.model {
        view.model = Some(value.clone());
    }
    if let Some(value) = &patch.mode {
        view.mode = Some(value.clone());
    }
    if let Some(value) = &patch.avatar_shape {
        view.avatar_shape = Some(value.clone());
    }
    if let Some(value) = &patch.avatar_color {
        view.avatar_color = Some(value.clone());
    }
    view.updated_at = Some(now_rfc3339());
}

/// Durable member settings surface mounted on [`crate::state::AppState`].
#[async_trait]
pub trait MemberSettingsService: Send + Sync {
    /// Settings view for `member_id`. Unknown-but-valid members get the empty
    /// view (`{memberId, avatar:null, …}`) without persisting anything;
    /// malformed ids are [`StoreError::Invalid`].
    async fn get(&self, member_id: &str) -> Result<MemberSettingsView, StoreError>;

    /// Apply a validated patch, creating the record on first write.
    async fn patch(
        &self,
        member_id: &str,
        patch: MemberSettingsPatch,
    ) -> Result<MemberSettingsView, StoreError>;

    /// Store (or replace) a decoded avatar (`image/png` | `image/jpeg`,
    /// 1..=512 KiB).
    async fn put_avatar(
        &self,
        member_id: &str,
        content_type: &str,
        bytes: Vec<u8>,
    ) -> Result<MemberSettingsView, StoreError>;

    /// Read the stored avatar blob, `None` when the member has no avatar.
    async fn get_avatar(&self, member_id: &str) -> Result<Option<StoredAvatar>, StoreError>;

    /// Delete the stored avatar; `true` when one existed.
    async fn delete_avatar(&self, member_id: &str) -> Result<bool, StoreError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png_bytes() -> Vec<u8> {
        b"\x89PNG\r\n\x1a\nfake-png-payload".to_vec()
    }

    async fn exercise_service(service: &dyn MemberSettingsService) {
        // A valid-but-unconfigured member reads as the empty view.
        let empty = service.get("grokbot").await.expect("get empty");
        assert_eq!(empty.member_id, "grokbot");
        assert!(empty.display_name.is_none());
        assert!(empty.avatar.is_none());
        assert!(empty.bindings.is_empty());
        assert!(empty.updated_at.is_none());

        let patched = service
            .patch(
                "grokbot",
                MemberSettingsPatch {
                    display_name: Some("Grok Bot".into()),
                    model: Some("gpt-5".into()),
                    mode: Some("safe".into()),
                    avatar_shape: Some("circle".into()),
                    avatar_color: Some("#112233".into()),
                },
            )
            .await
            .expect("patch");
        assert_eq!(patched.display_name.as_deref(), Some("Grok Bot"));
        assert_eq!(patched.model.as_deref(), Some("gpt-5"));
        assert_eq!(patched.mode.as_deref(), Some("safe"));
        assert_eq!(patched.avatar_shape.as_deref(), Some("circle"));
        assert_eq!(patched.avatar_color.as_deref(), Some("#112233"));
        assert!(patched.updated_at.is_some());
        assert_eq!(
            service.get("grokbot").await.expect("get").display_name,
            Some("Grok Bot".into())
        );

        // Partial patch keeps the other fields.
        let partial = service
            .patch(
                "grokbot",
                MemberSettingsPatch {
                    mode: Some("yolo".into()),
                    ..MemberSettingsPatch::default()
                },
            )
            .await
            .expect("partial patch");
        assert_eq!(partial.mode.as_deref(), Some("yolo"));
        assert_eq!(partial.display_name.as_deref(), Some("Grok Bot"));

        // Avatar lifecycle.
        assert!(
            service
                .get_avatar("grokbot")
                .await
                .expect("no avatar")
                .is_none()
        );
        let with_avatar = service
            .put_avatar("grokbot", "image/png", png_bytes())
            .await
            .expect("put avatar");
        let avatar = with_avatar.avatar.expect("avatar view");
        assert_eq!(avatar.content_type, "image/png");
        assert_eq!(avatar.size_bytes, png_bytes().len() as u64);
        assert_eq!(avatar.sha256, sha256_hex(&png_bytes()));
        assert_eq!(avatar.avatar_id, avatar.sha256);
        assert!(avatar.updated_at.ends_with('Z'));
        let stored = service
            .get_avatar("grokbot")
            .await
            .expect("stored")
            .expect("present");
        assert_eq!(stored.content_type, "image/png");
        assert_eq!(stored.bytes, png_bytes());
        assert!(service.delete_avatar("grokbot").await.expect("delete"));
        assert!(
            !service
                .delete_avatar("grokbot")
                .await
                .expect("delete again")
        );
        assert!(
            service
                .get_avatar("grokbot")
                .await
                .expect("after delete")
                .is_none()
        );
        // The settings record itself survives an avatar delete.
        assert_eq!(
            service.get("grokbot").await.expect("settings").mode,
            Some("yolo".into())
        );
    }

    #[tokio::test]
    async fn in_memory_store_round_trips() {
        let service = InMemoryMemberSettingsService::new();
        exercise_service(&service).await;
    }

    #[tokio::test]
    async fn malformed_member_ids_are_rejected() {
        let service = InMemoryMemberSettingsService::new();
        let long = "x".repeat(MAX_MEMBER_ID_LEN + 1);
        for bad in ["", "   ", "a/b", "bad\nid", long.as_str()] {
            let error = service.get(bad).await.expect_err("bad member id");
            assert!(matches!(error, StoreError::Invalid { .. }), "{error}");
        }
    }

    #[tokio::test]
    async fn patch_validation_rules() {
        let service = InMemoryMemberSettingsService::new();
        let empty = service
            .patch("human", MemberSettingsPatch::default())
            .await
            .expect_err("empty patch");
        assert!(matches!(empty, StoreError::Invalid { .. }));

        for bad in [
            MemberSettingsPatch {
                display_name: Some("  ".into()),
                ..MemberSettingsPatch::default()
            },
            MemberSettingsPatch {
                display_name: Some("x".repeat(MAX_DISPLAY_NAME_LEN + 1)),
                ..MemberSettingsPatch::default()
            },
            MemberSettingsPatch {
                model: Some("m".repeat(MAX_MODEL_LEN + 1)),
                ..MemberSettingsPatch::default()
            },
            MemberSettingsPatch {
                mode: Some("turbo".into()),
                ..MemberSettingsPatch::default()
            },
            MemberSettingsPatch {
                avatar_shape: Some("s".repeat(MAX_AVATAR_STYLE_LEN + 1)),
                ..MemberSettingsPatch::default()
            },
            MemberSettingsPatch {
                avatar_color: Some("".into()),
                ..MemberSettingsPatch::default()
            },
        ] {
            let error = service
                .patch("human", bad)
                .await
                .expect_err("invalid patch");
            assert!(matches!(error, StoreError::Invalid { .. }), "{error}");
        }
        // Failed patches leave no record behind.
        assert!(
            service
                .get("human")
                .await
                .expect("get")
                .updated_at
                .is_none()
        );
    }

    #[tokio::test]
    async fn avatar_validation_rules() {
        let service = InMemoryMemberSettingsService::new();
        for (content_type, bytes) in [
            ("image/gif", png_bytes()),
            ("text/plain", png_bytes()),
            ("image/png", Vec::new()),
            ("image/jpeg", vec![0u8; MAX_AVATAR_BYTES + 1]),
        ] {
            let error = service
                .put_avatar("human", content_type, bytes)
                .await
                .expect_err("invalid avatar");
            assert!(matches!(error, StoreError::Invalid { .. }), "{error}");
        }
        assert!(
            service
                .get_avatar("human")
                .await
                .expect("no avatar")
                .is_none()
        );
    }

    #[tokio::test]
    async fn file_store_survives_reopen() {
        let dir = tempfile::tempdir().expect("tempdir");
        let settings_path = dir.path().join(MEMBER_SETTINGS_FILE);
        let avatar = {
            let service = FileMemberSettingsService::open_in(dir.path()).expect("open");
            assert!(
                !settings_path.exists(),
                "open must not write an empty store"
            );
            service
                .patch(
                    "human",
                    MemberSettingsPatch {
                        display_name: Some("Pai".into()),
                        avatar_shape: Some("squircle".into()),
                        avatar_color: Some("#abcdef".into()),
                        ..MemberSettingsPatch::default()
                    },
                )
                .await
                .expect("patch");
            service
                .put_avatar("human", "image/png", png_bytes())
                .await
                .expect("put avatar")
                .avatar
                .expect("avatar view")
        };
        assert!(settings_path.is_file());
        let raw = std::fs::read_to_string(&settings_path).expect("read settings");
        let json: serde_json::Value = serde_json::from_str(&raw).expect("json");
        assert_eq!(json["version"], MEMBER_SETTINGS_STORE_VERSION);
        assert_eq!(json["members"].as_array().expect("members").len(), 1);
        assert_eq!(json["members"][0]["memberId"], "human");
        let avatar_path = dir
            .path()
            .join(AVATARS_DIR)
            .join(format!("{}.png", avatar.sha256));
        assert_eq!(
            std::fs::read(&avatar_path).expect("avatar blob"),
            png_bytes()
        );

        let reopened = FileMemberSettingsService::open_in(dir.path()).expect("reopen");
        let view = reopened.get("human").await.expect("get");
        assert_eq!(view.display_name.as_deref(), Some("Pai"));
        assert_eq!(view.avatar_shape.as_deref(), Some("squircle"));
        assert_eq!(
            reopened
                .get_avatar("human")
                .await
                .expect("avatar")
                .expect("present")
                .bytes,
            png_bytes()
        );
        assert!(reopened.delete_avatar("human").await.expect("delete"));
        assert!(!avatar_path.exists(), "unreferenced avatar blob is removed");
        drop(reopened);

        let reopened_again = FileMemberSettingsService::open_in(dir.path()).expect("reopen");
        assert!(
            reopened_again
                .get_avatar("human")
                .await
                .expect("no avatar")
                .is_none()
        );
        assert_eq!(
            reopened_again
                .get("human")
                .await
                .expect("settings")
                .display_name,
            Some("Pai".into())
        );
    }

    #[test]
    fn corrupt_settings_file_is_a_hard_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(MEMBER_SETTINGS_FILE);
        std::fs::write(&path, b"{ not json").expect("write corrupt");
        assert!(matches!(
            FileMemberSettingsService::open_in(dir.path()),
            Err(StoreError::Corrupt { .. })
        ));
        assert_eq!(std::fs::read(&path).expect("read"), b"{ not json".to_vec());
        std::fs::write(&path, br#"{"version":7,"members":[]}"#).expect("write version");
        assert!(matches!(
            FileMemberSettingsService::open_in(dir.path()),
            Err(StoreError::Corrupt { .. })
        ));
    }

    #[tokio::test]
    async fn missing_avatar_blob_is_corrupt() {
        let dir = tempfile::tempdir().expect("tempdir");
        let avatar = {
            let service = FileMemberSettingsService::open_in(dir.path()).expect("open");
            service
                .put_avatar("human", "image/jpeg", b"jpgdata".to_vec())
                .await
                .expect("put avatar")
                .avatar
                .expect("avatar")
        };
        std::fs::remove_file(
            dir.path()
                .join(AVATARS_DIR)
                .join(format!("{}.jpg", avatar.sha256)),
        )
        .expect("remove blob");
        let reopened = FileMemberSettingsService::open_in(dir.path()).expect("reopen");
        let error = reopened
            .get_avatar("human")
            .await
            .expect_err("missing avatar blob must be corrupt");
        assert!(matches!(error, StoreError::Corrupt { .. }), "{error}");
    }

    #[tokio::test]
    async fn shared_avatar_blob_survives_until_last_reference() {
        let dir = tempfile::tempdir().expect("tempdir");
        {
            let service = FileMemberSettingsService::open_in(dir.path()).expect("open");
            service
                .put_avatar("human", "image/png", png_bytes())
                .await
                .expect("human avatar");
            service
                .put_avatar("grokbot", "image/png", png_bytes())
                .await
                .expect("grokbot avatar");
            assert!(service.delete_avatar("human").await.expect("delete human"));
            let blob = dir
                .path()
                .join(AVATARS_DIR)
                .join(format!("{}.png", sha256_hex(&png_bytes())));
            assert!(blob.is_file(), "blob is still referenced by grokbot");
            assert!(service.delete_avatar("grokbot").await.expect("delete"));
            assert!(!blob.exists(), "last reference removed the blob");
        }
    }

    #[tokio::test]
    async fn unknown_member_avatar_is_none_and_invalid_id_is_error() {
        let service = InMemoryMemberSettingsService::new();
        assert!(
            service
                .get_avatar("never-configured")
                .await
                .expect("none")
                .is_none()
        );
        assert!(
            service
                .get_avatar("bad/id")
                .await
                .expect_err("invalid id")
                .to_string()
                .contains("memberId")
        );
    }
}
