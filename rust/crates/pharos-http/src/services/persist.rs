//! Shared durable JSON store helpers for the web-endpoints stores.
//!
//! [`crate::services::bindings`], [`crate::services::member_settings`] and
//! [`crate::services::attachments`] all persist one versioned JSON document per
//! store (plus raw blob files for avatars/attachments) under the single Host
//! data dir.
//!
//! Guarantees provided here:
//! - writes are atomic: serialize → temp file in the same directory → `fsync`
//!   → `rename` over the target. A crash never leaves a half-written document.
//! - reads are strict: a missing file means "empty store"; an existing empty,
//!   truncated, non-JSON or wrong-version file is a hard [`StoreError::Corrupt`]
//!   error. Corrupt state is never silently reset to empty (that would fake a
//!   clean state and lose user data).
//! - timestamps are RFC3339 UTC, matching the frozen API contract.
//!
//! It also hosts the small dependency-free [`sha256_hex`] used for
//! content-addressed avatar file names and attachment digests (the crate does
//! not depend on `sha2`, and this stream must not add new dependencies).

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::Serialize;
use serde::de::DeserializeOwned;
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

/// Error surface shared by all durable web-endpoint stores.
///
/// The HTTP layer maps:
/// - [`StoreError::Invalid`] → `400 invalidRequest`
/// - [`StoreError::Io`] / [`StoreError::Corrupt`] → `502 operationFailed`
///
/// Startup wiring surfaces any variant as a hard error (never a silent reset).
#[derive(Debug, Error)]
pub enum StoreError {
    #[error("store io error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("store data is corrupt: {detail}")]
    Corrupt { detail: String },
    #[error("invalid request: {message}")]
    Invalid { message: String },
}

impl StoreError {
    /// Build an `invalidRequest`-shaped store error (HTTP 400).
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::Invalid {
            message: message.into(),
        }
    }

    /// Build a corruption error for a specific store path.
    pub fn corrupt(path: &Path, detail: impl std::fmt::Display) -> Self {
        Self::Corrupt {
            detail: format!("{}: {detail}", path.display()),
        }
    }

    fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        Self::Io {
            path: path.into(),
            source,
        }
    }
}

static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Read a versioned JSON store document.
///
/// - missing file → `Ok(None)` (first run: store is created on first write)
/// - empty / whitespace-only / invalid JSON / unsupported version → `Err`
///   ([`StoreError::Corrupt`]) so a damaged store is never treated as empty
/// - otherwise → `Ok(Some(document))`
pub fn read_versioned_store<T: DeserializeOwned>(
    path: &Path,
    expected_version: u32,
    version_of: impl Fn(&T) -> u32,
) -> Result<Option<T>, StoreError> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(source) => return Err(StoreError::io(path, source)),
    };
    if bytes.iter().all(u8::is_ascii_whitespace) {
        // An existing but empty file is not a fresh store: refusing to guess
        // avoids silently discarding a truncated record set.
        return Err(StoreError::corrupt(path, "store file is empty"));
    }
    let document: T = serde_json::from_slice(&bytes)
        .map_err(|error| StoreError::corrupt(path, format!("invalid JSON: {error}")))?;
    let version = version_of(&document);
    if version != expected_version {
        return Err(StoreError::corrupt(
            path,
            format!("unsupported store version {version} (expected {expected_version})"),
        ));
    }
    Ok(Some(document))
}

/// Atomically write a JSON document: temp file + `fsync` + rename.
pub fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<(), StoreError> {
    let bytes = serde_json::to_vec_pretty(value)
        .map_err(|error| StoreError::corrupt(path, format!("serialize: {error}")))?;
    write_bytes_atomic(path, &bytes)
}

/// Atomically write raw bytes: temp file + `fsync` + rename.
///
/// Used for avatar and attachment blobs as well as the JSON index files so a
/// crash cannot leave a partially written file behind.
pub fn write_bytes_atomic(path: &Path, bytes: &[u8]) -> Result<(), StoreError> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent).map_err(|source| StoreError::io(parent, source))?;
    }
    let counter = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = temp_path(path, counter);
    write_and_sync(&tmp, bytes)?;
    fs::rename(&tmp, path).map_err(|source| {
        // Best effort cleanup; the original error is what matters.
        let _ = fs::remove_file(&tmp);
        StoreError::io(path, source)
    })
}

fn temp_path(path: &Path, counter: u64) -> PathBuf {
    let file_name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "store".to_string());
    path.with_file_name(format!(".{file_name}.tmp.{}.{counter}", std::process::id()))
}

fn write_and_sync(path: &Path, bytes: &[u8]) -> Result<(), StoreError> {
    let mut file = fs::File::create(path).map_err(|source| StoreError::io(path, source))?;
    file.write_all(bytes)
        .map_err(|source| StoreError::io(path, source))?;
    // Flush to disk before the atomic rename so a crash cannot leave the target
    // pointing at empty/partial data.
    file.sync_all()
        .map_err(|source| StoreError::io(path, source))
}

/// Read a raw blob file. `Ok(None)` when it does not exist.
pub fn read_blob(path: &Path) -> Result<Option<Vec<u8>>, StoreError> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(StoreError::io(path, source)),
    }
}

/// Current UTC time formatted as RFC3339 (`2026-11-11T10:00:00Z`).
pub fn now_rfc3339() -> String {
    let now = OffsetDateTime::now_utc();
    now.format(&Rfc3339)
        // `Rfc3339` formatting of a valid `OffsetDateTime` cannot fail; fall
        // back to a fixed epoch instead of panicking in a server path.
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

/// Lowercase hex SHA-256 digest of `bytes`.
///
/// The contract uses SHA-256 for avatar file names and attachment metadata,
/// and this crate does not depend on `sha2`; the implementation lives here to
/// avoid adding a new external dependency to the workspace.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex_lower(&sha256(bytes))
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from_digit((byte >> 4) as u32, 16).expect("nibble"));
        out.push(char::from_digit((byte & 0x0f) as u32, 16).expect("nibble"));
    }
    out
}

const SHA256_INIT: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

const SHA256_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

fn sha256(input: &[u8]) -> [u8; 32] {
    let mut state = SHA256_INIT;
    let mut message = input.to_vec();
    let bit_len = (input.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in message.as_chunks::<64>().0 {
        let mut words = [0u32; 64];
        for (i, word) in words.iter_mut().take(16).enumerate() {
            let start = i * 4;
            *word = u32::from_be_bytes([
                chunk[start],
                chunk[start + 1],
                chunk[start + 2],
                chunk[start + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = words[i - 15].rotate_right(7)
                ^ words[i - 15].rotate_right(18)
                ^ (words[i - 15] >> 3);
            let s1 = words[i - 2].rotate_right(17)
                ^ words[i - 2].rotate_right(19)
                ^ (words[i - 2] >> 10);
            words[i] = words[i - 16]
                .wrapping_add(s0)
                .wrapping_add(words[i - 7])
                .wrapping_add(s1);
        }

        let mut a = state[0];
        let mut b = state[1];
        let mut c = state[2];
        let mut d = state[3];
        let mut e = state[4];
        let mut f = state[5];
        let mut g = state[6];
        let mut h = state[7];

        for i in 0..64 {
            let sum1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choose = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(sum1)
                .wrapping_add(choose)
                .wrapping_add(SHA256_K[i])
                .wrapping_add(words[i]);
            let sum0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = sum0.wrapping_add(majority);

            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        state[0] = state[0].wrapping_add(a);
        state[1] = state[1].wrapping_add(b);
        state[2] = state[2].wrapping_add(c);
        state[3] = state[3].wrapping_add(d);
        state[4] = state[4].wrapping_add(e);
        state[5] = state[5].wrapping_add(f);
        state[6] = state[6].wrapping_add(g);
        state[7] = state[7].wrapping_add(h);
    }

    let mut digest = [0u8; 32];
    for (i, word) in state.iter().enumerate() {
        digest[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    digest
}

// ---------------------------------------------------------------------------
// base64 (dependency-free, strict standard alphabet with padding)
// ---------------------------------------------------------------------------

fn base64_value(byte: u8) -> Result<u8, String> {
    match byte {
        b'A'..=b'Z' => Ok(byte - b'A'),
        b'a'..=b'z' => Ok(byte - b'a' + 26),
        b'0'..=b'9' => Ok(byte - b'0' + 52),
        b'+' => Ok(62),
        b'/' => Ok(63),
        _ => Err(format!(
            "invalid character (byte 0x{byte:02x}); expected A-Z, a-z, 0-9, +, / or '='"
        )),
    }
}

/// Decode strict standard base64 (`A-Za-z0-9+/`, `=` padding, no whitespace).
///
/// Empty input decodes to empty bytes. Malformed input (wrong length, padding
/// in the middle, non-alphabet characters) is an error: callers must answer
/// `400 invalidRequest` instead of storing silently truncated bytes. The
/// decoded size limit is the caller's responsibility (attachments 10 MiB,
/// avatars 512 KiB).
pub fn decode_base64(input: &str) -> Result<Vec<u8>, String> {
    let bytes = input.as_bytes();
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if !bytes.len().is_multiple_of(4) {
        return Err("length must be a multiple of 4".to_string());
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let total = bytes.len() / 4;
    for (index, chunk) in bytes.as_chunks::<4>().0.iter().enumerate() {
        let chunk: &[u8] = chunk.as_slice();
        let last = index + 1 == total;
        if !last && chunk.contains(&b'=') {
            return Err("padding before the final quartet".to_string());
        }
        match chunk {
            [c0, c1, b'=', b'='] => {
                let value0 = base64_value(*c0)?;
                let value1 = base64_value(*c1)?;
                out.push((value0 << 2) | (value1 >> 4));
            }
            [c0, c1, c2, b'='] => {
                let value0 = base64_value(*c0)?;
                let value1 = base64_value(*c1)?;
                let value2 = base64_value(*c2)?;
                out.push((value0 << 2) | (value1 >> 4));
                out.push((value1 << 4) | (value2 >> 2));
            }
            [b'=', ..] => return Err("leading padding".to_string()),
            [c0, c1, c2, c3] => {
                let value0 = base64_value(*c0)?;
                let value1 = base64_value(*c1)?;
                let value2 = base64_value(*c2)?;
                let value3 = base64_value(*c3)?;
                out.push((value0 << 2) | (value1 >> 4));
                out.push((value1 << 4) | (value2 >> 2));
                out.push((value2 << 6) | value3);
            }
            _ => unreachable!("chunks_exact(4) always yields four bytes"),
        }
    }
    Ok(out)
}

/// Encode bytes as standard padded base64 (tests and future clients).
pub fn encode_base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        match chunk {
            [b0, b1, b2] => {
                out.push(ALPHABET[(b0 >> 2) as usize] as char);
                out.push(ALPHABET[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
                out.push(ALPHABET[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
                out.push(ALPHABET[(b2 & 0x3f) as usize] as char);
            }
            [b0, b1] => {
                out.push(ALPHABET[(b0 >> 2) as usize] as char);
                out.push(ALPHABET[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
                out.push(ALPHABET[((b1 & 0x0f) << 2) as usize] as char);
                out.push('=');
            }
            [b0] => {
                out.push(ALPHABET[(b0 >> 2) as usize] as char);
                out.push(ALPHABET[((b0 & 0x03) << 4) as usize] as char);
                out.push('=');
                out.push('=');
            }
            _ => unreachable!("chunks(3) yields 1..=3 bytes"),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};

    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Envelope {
        version: u32,
        items: Vec<String>,
    }

    fn version_of(document: &Envelope) -> u32 {
        document.version
    }

    #[test]
    fn versioned_store_round_trip() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("nested").join("store.json");
        assert_eq!(
            read_versioned_store::<Envelope>(&path, 1, version_of).expect("missing"),
            None
        );
        let document = Envelope {
            version: 1,
            items: vec!["a".into(), "b".into()],
        };
        write_json_atomic(&path, &document).expect("write");
        let loaded = read_versioned_store(&path, 1, version_of)
            .expect("read")
            .expect("present");
        assert_eq!(loaded, document);
        // The write is atomic: no temp siblings are left behind.
        let leftovers: Vec<_> = fs::read_dir(path.parent().unwrap())
            .expect("dir")
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.file_name().to_string_lossy().contains(".tmp."))
            .collect();
        assert!(leftovers.is_empty(), "temp files must be renamed away");
    }

    #[test]
    fn corrupt_store_is_a_hard_error_and_bytes_are_preserved() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("store.json");
        fs::write(&path, b"{ not json").expect("write corrupt");
        let error = read_versioned_store::<Envelope>(&path, 1, version_of).expect_err("corrupt");
        assert!(matches!(error, StoreError::Corrupt { .. }), "{error}");
        assert_eq!(
            fs::read(&path).expect("read back"),
            b"{ not json".to_vec(),
            "corrupt bytes must be preserved for inspection"
        );

        // An existing but empty/truncated store is also corrupt, not "fresh".
        fs::write(&path, b"  \n").expect("write blank");
        assert!(matches!(
            read_versioned_store::<Envelope>(&path, 1, version_of),
            Err(StoreError::Corrupt { .. })
        ));
    }

    #[test]
    fn unsupported_store_version_is_a_hard_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("store.json");
        fs::write(&path, br#"{"version":2,"items":[]}"#).expect("write future version");
        let error = read_versioned_store::<Envelope>(&path, 1, version_of).expect_err("version");
        match error {
            StoreError::Corrupt { detail } => {
                assert!(detail.contains("unsupported store version 2"), "{detail}");
            }
            other => panic!("expected corrupt, got {other:?}"),
        }
    }

    #[test]
    fn sha256_matches_known_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b"hello world"),
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        );
        // Multi-block input (> 64 bytes) exercises the chunking path.
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }

    #[test]
    fn base64_round_trips_known_vectors() {
        for (raw, encoded) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(encode_base64(raw.as_bytes()), encoded);
            assert_eq!(decode_base64(encoded).expect("decode"), raw.as_bytes());
        }
        assert_eq!(
            decode_base64("aGVsbG8sIHdvcmxkIQ==").expect("hello"),
            b"hello, world!".to_vec()
        );
        assert_eq!(decode_base64("AAEC").expect("bytes"), vec![0u8, 1, 2]);
    }

    #[test]
    fn base64_rejects_malformed_input() {
        for bad in [
            "a",
            "ab",
            "abc",
            "!!!!",
            "aGVsbG8",
            "aGVsbG8==",
            "ab=c",
            "YWJj\n",
            "aG=sbG8=",
            "====",
        ] {
            assert!(
                decode_base64(bad).is_err(),
                "{bad:?} must be rejected as invalid base64"
            );
        }
    }

    #[test]
    fn now_is_rfc3339_utc() {
        let raw = now_rfc3339();
        assert!(raw.ends_with('Z'), "{raw}");
        let parsed = OffsetDateTime::parse(&raw, &Rfc3339).expect("parse");
        assert_eq!(parsed.offset(), time::UtcOffset::UTC);
    }

    #[test]
    fn write_bytes_atomic_creates_parents_and_replaces() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("a/b/blob.bin");
        write_bytes_atomic(&path, b"first").expect("first");
        write_bytes_atomic(&path, b"second").expect("second");
        assert_eq!(fs::read(&path).expect("read"), b"second".to_vec());
        assert_eq!(
            read_blob(&path).expect("blob").as_deref(),
            Some(&b"second"[..])
        );
        assert_eq!(
            read_blob(&dir.path().join("missing.bin")).expect("missing"),
            None
        );
    }
}
