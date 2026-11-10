//! Binary PHM1 framing used on one Iroh QUIC stream.
//!
//! Layout (big-endian), matching Swift `MeshStreamFrameCodec`:
//! ```text
//! magic[4]=PHM1 | kind[1] | reserved[3]=0 | header_len u32 | body_len u64 | header | body
//! ```

use std::io;

use thiserror::Error;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Swift `DistributedMeshProtocol.maximumHeaderBytes`.
pub const MAXIMUM_HEADER_BYTES: usize = 4 * 1024 * 1024;
/// Swift `DistributedMeshProtocol.maximumBlobBytes`.
pub const MAXIMUM_BODY_BYTES: usize = 25 * 1024 * 1024;
pub const PREFIX_BYTE_COUNT: usize = 20;

const MAGIC: [u8; 4] = [0x50, 0x48, 0x4d, 0x31]; // PHM1

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MeshStreamFrameKind {
    Request = 1,
    Response = 2,
}

impl MeshStreamFrameKind {
    fn from_u8(value: u8) -> Option<Self> {
        match value {
            1 => Some(Self::Request),
            2 => Some(Self::Response),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MeshStreamFrame {
    pub kind: MeshStreamFrameKind,
    pub header: Vec<u8>,
    pub body: Option<Vec<u8>>,
}

#[derive(Debug, Error)]
pub enum FrameError {
    #[error("truncated PHM1 prefix")]
    TruncatedPrefix,
    #[error("invalid PHM1 magic")]
    InvalidMagic,
    #[error("invalid frame kind")]
    InvalidKind,
    #[error("nonzero reserved bytes")]
    NonzeroReserved,
    #[error("empty header")]
    EmptyHeader,
    #[error("header too large")]
    HeaderTooLarge,
    #[error("body too large")]
    BodyTooLarge,
    #[error("frame length mismatch")]
    LengthMismatch,
    #[error("io: {0}")]
    Io(#[from] io::Error),
}

pub fn encode_frame(frame: &MeshStreamFrame) -> Result<Vec<u8>, FrameError> {
    validate(frame.header.len(), frame.body.as_ref().map_or(0, Vec::len))?;
    let body_len = frame.body.as_ref().map_or(0, Vec::len);
    let mut out = Vec::with_capacity(PREFIX_BYTE_COUNT + frame.header.len() + body_len);
    out.extend_from_slice(&MAGIC);
    out.push(frame.kind as u8);
    out.extend_from_slice(&[0, 0, 0]);
    out.extend_from_slice(&(frame.header.len() as u32).to_be_bytes());
    out.extend_from_slice(&(body_len as u64).to_be_bytes());
    out.extend_from_slice(&frame.header);
    if let Some(body) = &frame.body {
        out.extend_from_slice(body);
    }
    Ok(out)
}

pub fn decode_frame(data: &[u8]) -> Result<MeshStreamFrame, FrameError> {
    if data.len() < PREFIX_BYTE_COUNT {
        return Err(FrameError::TruncatedPrefix);
    }
    if data[0..4] != MAGIC {
        return Err(FrameError::InvalidMagic);
    }
    let kind = MeshStreamFrameKind::from_u8(data[4]).ok_or(FrameError::InvalidKind)?;
    if data[5] != 0 || data[6] != 0 || data[7] != 0 {
        return Err(FrameError::NonzeroReserved);
    }
    let header_len = u32::from_be_bytes(data[8..12].try_into().unwrap()) as usize;
    let body_len = u64::from_be_bytes(data[12..20].try_into().unwrap()) as usize;
    validate(header_len, body_len)?;
    if PREFIX_BYTE_COUNT + header_len + body_len != data.len() {
        return Err(FrameError::LengthMismatch);
    }
    let header_end = PREFIX_BYTE_COUNT + header_len;
    let header = data[PREFIX_BYTE_COUNT..header_end].to_vec();
    let body = if body_len == 0 {
        None
    } else {
        Some(data[header_end..].to_vec())
    };
    Ok(MeshStreamFrame { kind, header, body })
}

fn validate(header_len: usize, body_len: usize) -> Result<(), FrameError> {
    if header_len == 0 {
        return Err(FrameError::EmptyHeader);
    }
    if header_len > MAXIMUM_HEADER_BYTES {
        return Err(FrameError::HeaderTooLarge);
    }
    if body_len > MAXIMUM_BODY_BYTES {
        return Err(FrameError::BodyTooLarge);
    }
    Ok(())
}

pub async fn write_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    frame: &MeshStreamFrame,
) -> Result<(), FrameError> {
    let bytes = encode_frame(frame)?;
    writer.write_all(&bytes).await?;
    writer.flush().await?;
    Ok(())
}

/// Read one complete PHM1 frame from a stream (prefix then payload).
pub async fn read_frame<R: AsyncRead + Unpin>(
    reader: &mut R,
) -> Result<MeshStreamFrame, FrameError> {
    let mut prefix = [0u8; PREFIX_BYTE_COUNT];
    reader.read_exact(&mut prefix).await?;
    if prefix[0..4] != MAGIC {
        return Err(FrameError::InvalidMagic);
    }
    let kind = MeshStreamFrameKind::from_u8(prefix[4]).ok_or(FrameError::InvalidKind)?;
    if prefix[5] != 0 || prefix[6] != 0 || prefix[7] != 0 {
        return Err(FrameError::NonzeroReserved);
    }
    let header_len = u32::from_be_bytes(prefix[8..12].try_into().unwrap()) as usize;
    let body_len = u64::from_be_bytes(prefix[12..20].try_into().unwrap()) as usize;
    validate(header_len, body_len)?;
    let mut payload = vec![0u8; header_len + body_len];
    if !payload.is_empty() {
        reader.read_exact(&mut payload).await?;
    }
    let header = payload[..header_len].to_vec();
    let body = if body_len == 0 {
        None
    } else {
        Some(payload[header_len..].to_vec())
    };
    Ok(MeshStreamFrame { kind, header, body })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_request_with_body() {
        let frame = MeshStreamFrame {
            kind: MeshStreamFrameKind::Request,
            header: b"{\"v\":1}".to_vec(),
            body: Some(b"payload".to_vec()),
        };
        let encoded = encode_frame(&frame).unwrap();
        assert_eq!(&encoded[0..4], &MAGIC);
        let decoded = decode_frame(&encoded).unwrap();
        assert_eq!(decoded, frame);
    }

    #[test]
    fn rejects_bad_magic() {
        let mut encoded = encode_frame(&MeshStreamFrame {
            kind: MeshStreamFrameKind::Response,
            header: b"h".to_vec(),
            body: None,
        })
        .unwrap();
        encoded[0] = 0;
        assert!(matches!(
            decode_frame(&encoded),
            Err(FrameError::InvalidMagic)
        ));
    }

    #[tokio::test]
    async fn async_read_write_roundtrip() {
        let (mut client, mut server) = tokio::io::duplex(64 * 1024);
        let frame = MeshStreamFrame {
            kind: MeshStreamFrameKind::Request,
            header: b"hdr".to_vec(),
            body: Some(vec![1, 2, 3]),
        };
        write_frame(&mut client, &frame).await.unwrap();
        let got = read_frame(&mut server).await.unwrap();
        assert_eq!(got, frame);
    }
}
