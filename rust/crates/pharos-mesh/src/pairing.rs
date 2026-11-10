//! Trust-group invite / accept smoke protocol (msg-test only).
//!
//! This is a Rust-native pairing envelope inspired by Swift
//! `MeshTrustInvitation`, simplified for S3 acceptance. It is not claimed to be
//! bit-compatible with production Swift QR tickets.

use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
#[derive(Debug, Error)]
pub enum PairingError {
    #[error("invalid invitation: {0}")]
    Invalid(String),
    #[error("expired invitation")]
    Expired,
    #[error("signature verification failed")]
    BadSignature,
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TrustInvitation {
    pub protocol_version: u32,
    pub trust_group_id: String,
    pub membership_epoch: u64,
    pub inviter_device_id: String,
    pub inviter_endpoint_id: String,
    pub inviter_address_ticket: String,
    pub inviter_signing_public_key_b64: String,
    pub inviter_roles: Vec<String>,
    pub requested_roles: Vec<String>,
    pub issued_at_ms: i64,
    pub expires_at_ms: i64,
    pub nonce_b64: String,
    pub signature_b64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TrustAcceptance {
    pub protocol_version: u32,
    pub trust_group_id: String,
    pub membership_epoch: u64,
    pub accepter_device_id: String,
    pub accepter_endpoint_id: String,
    pub accepter_signing_public_key_b64: String,
    pub accepter_roles: Vec<String>,
    pub invitation_digest_b64: String,
    pub accepted_at_ms: i64,
    pub signature_b64: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UnsignedInvitation<'a> {
    protocol_version: u32,
    trust_group_id: &'a str,
    membership_epoch: u64,
    inviter_device_id: &'a str,
    inviter_endpoint_id: &'a str,
    inviter_address_ticket: &'a str,
    inviter_signing_public_key_b64: &'a str,
    inviter_roles: &'a [String],
    requested_roles: &'a [String],
    issued_at_ms: i64,
    expires_at_ms: i64,
    nonce_b64: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UnsignedAcceptance<'a> {
    protocol_version: u32,
    trust_group_id: &'a str,
    membership_epoch: u64,
    accepter_device_id: &'a str,
    accepter_endpoint_id: &'a str,
    accepter_signing_public_key_b64: &'a str,
    accepter_roles: &'a [String],
    invitation_digest_b64: &'a str,
    accepted_at_ms: i64,
}

#[derive(Debug, Clone)]
pub struct IssueInvitationArgs<'a> {
    pub trust_group_id: &'a str,
    pub membership_epoch: u64,
    pub inviter_device_id: &'a str,
    pub inviter_endpoint_id: &'a str,
    pub inviter_address_ticket: &'a str,
    pub inviter_roles: Vec<String>,
    pub requested_roles: Vec<String>,
    pub lifetime_ms: i64,
}

pub fn issue_invitation(
    signing: &SigningKey,
    args: IssueInvitationArgs<'_>,
) -> Result<TrustInvitation, PairingError> {
    if args.membership_epoch == 0 {
        return Err(PairingError::Invalid("membership epoch".into()));
    }
    if !args.inviter_roles.iter().any(|r| r == "controller") {
        return Err(PairingError::Invalid(
            "inviter must include controller role".into(),
        ));
    }
    let now = now_ms();
    let mut nonce = [0u8; 32];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut nonce);
    let mut invitation = TrustInvitation {
        protocol_version: 1,
        trust_group_id: args.trust_group_id.to_string(),
        membership_epoch: args.membership_epoch,
        inviter_device_id: args.inviter_device_id.to_string(),
        inviter_endpoint_id: args.inviter_endpoint_id.to_string(),
        inviter_address_ticket: args.inviter_address_ticket.to_string(),
        inviter_signing_public_key_b64: b64(signing.verifying_key().as_bytes()),
        inviter_roles: args.inviter_roles,
        requested_roles: args.requested_roles,
        issued_at_ms: now,
        expires_at_ms: now + args.lifetime_ms,
        nonce_b64: b64(&nonce),
        signature_b64: String::new(),
    };
    let bytes = unsigned_invitation_bytes(&invitation)?;
    let sig = signing.sign(&bytes);
    invitation.signature_b64 = b64(&sig.to_bytes());
    Ok(invitation)
}

pub fn accept_invitation(
    invitation: &TrustInvitation,
    accepter_signing: &SigningKey,
    accepter_device_id: &str,
    accepter_endpoint_id: &str,
    accepter_roles: Vec<String>,
) -> Result<TrustAcceptance, PairingError> {
    verify_invitation(invitation)?;
    let digest = invitation_digest(invitation)?;
    let now = now_ms();
    let mut acceptance = TrustAcceptance {
        protocol_version: 1,
        trust_group_id: invitation.trust_group_id.clone(),
        membership_epoch: invitation.membership_epoch,
        accepter_device_id: accepter_device_id.to_string(),
        accepter_endpoint_id: accepter_endpoint_id.to_string(),
        accepter_signing_public_key_b64: b64(accepter_signing.verifying_key().as_bytes()),
        accepter_roles,
        invitation_digest_b64: b64(&digest),
        accepted_at_ms: now,
        signature_b64: String::new(),
    };
    let bytes = unsigned_acceptance_bytes(&acceptance)?;
    let sig = accepter_signing.sign(&bytes);
    acceptance.signature_b64 = b64(&sig.to_bytes());
    Ok(acceptance)
}

pub fn verify_acceptance(
    invitation: &TrustInvitation,
    acceptance: &TrustAcceptance,
) -> Result<(), PairingError> {
    verify_invitation(invitation)?;
    if acceptance.trust_group_id != invitation.trust_group_id
        || acceptance.membership_epoch != invitation.membership_epoch
    {
        return Err(PairingError::Invalid("acceptance group mismatch".into()));
    }
    let expected = invitation_digest(invitation)?;
    let got = decode_b64(&acceptance.invitation_digest_b64)?;
    if got != expected {
        return Err(PairingError::Invalid("invitation digest mismatch".into()));
    }
    let key_bytes = decode_b64(&acceptance.accepter_signing_public_key_b64)?;
    if key_bytes.len() != 32 {
        return Err(PairingError::Invalid("accepter public key".into()));
    }
    let mut pk = [0u8; 32];
    pk.copy_from_slice(&key_bytes);
    let verifying = VerifyingKey::from_bytes(&pk)
        .map_err(|e| PairingError::Invalid(format!("accepter key: {e}")))?;
    let msg = unsigned_acceptance_bytes(acceptance)?;
    let sig_bytes = decode_b64(&acceptance.signature_b64)?;
    let sig = Signature::from_slice(&sig_bytes)
        .map_err(|e| PairingError::Invalid(format!("acceptance sig: {e}")))?;
    verifying
        .verify(&msg, &sig)
        .map_err(|_| PairingError::BadSignature)?;
    Ok(())
}

fn verify_invitation(invitation: &TrustInvitation) -> Result<(), PairingError> {
    if invitation.protocol_version != 1 {
        return Err(PairingError::Invalid("protocol version".into()));
    }
    if invitation.membership_epoch == 0 {
        return Err(PairingError::Invalid("membership epoch".into()));
    }
    if now_ms() > invitation.expires_at_ms {
        return Err(PairingError::Expired);
    }
    let key_bytes = decode_b64(&invitation.inviter_signing_public_key_b64)?;
    if key_bytes.len() != 32 {
        return Err(PairingError::Invalid("inviter public key".into()));
    }
    let mut pk = [0u8; 32];
    pk.copy_from_slice(&key_bytes);
    let verifying = VerifyingKey::from_bytes(&pk)
        .map_err(|e| PairingError::Invalid(format!("inviter key: {e}")))?;
    let msg = unsigned_invitation_bytes(invitation)?;
    let sig_bytes = decode_b64(&invitation.signature_b64)?;
    let sig = Signature::from_slice(&sig_bytes)
        .map_err(|e| PairingError::Invalid(format!("invitation sig: {e}")))?;
    verifying
        .verify(&msg, &sig)
        .map_err(|_| PairingError::BadSignature)?;
    Ok(())
}

fn invitation_digest(invitation: &TrustInvitation) -> Result<[u8; 32], PairingError> {
    let bytes = serde_json::to_vec(invitation)?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(hasher.finalize().into())
}

fn unsigned_invitation_bytes(invitation: &TrustInvitation) -> Result<Vec<u8>, PairingError> {
    let unsigned = UnsignedInvitation {
        protocol_version: invitation.protocol_version,
        trust_group_id: &invitation.trust_group_id,
        membership_epoch: invitation.membership_epoch,
        inviter_device_id: &invitation.inviter_device_id,
        inviter_endpoint_id: &invitation.inviter_endpoint_id,
        inviter_address_ticket: &invitation.inviter_address_ticket,
        inviter_signing_public_key_b64: &invitation.inviter_signing_public_key_b64,
        inviter_roles: &invitation.inviter_roles,
        requested_roles: &invitation.requested_roles,
        issued_at_ms: invitation.issued_at_ms,
        expires_at_ms: invitation.expires_at_ms,
        nonce_b64: &invitation.nonce_b64,
    };
    Ok(serde_json::to_vec(&unsigned)?)
}

fn unsigned_acceptance_bytes(acceptance: &TrustAcceptance) -> Result<Vec<u8>, PairingError> {
    let unsigned = UnsignedAcceptance {
        protocol_version: acceptance.protocol_version,
        trust_group_id: &acceptance.trust_group_id,
        membership_epoch: acceptance.membership_epoch,
        accepter_device_id: &acceptance.accepter_device_id,
        accepter_endpoint_id: &acceptance.accepter_endpoint_id,
        accepter_signing_public_key_b64: &acceptance.accepter_signing_public_key_b64,
        accepter_roles: &acceptance.accepter_roles,
        invitation_digest_b64: &acceptance.invitation_digest_b64,
        accepted_at_ms: acceptance.accepted_at_ms,
    };
    Ok(serde_json::to_vec(&unsigned)?)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn decode_b64(value: &str) -> Result<Vec<u8>, PairingError> {
    base64::engine::general_purpose::STANDARD
        .decode(value)
        .map_err(|e| PairingError::Invalid(format!("base64: {e}")))
}

/// Encode invitation as a single-line ticket for CLI transfer (not a secret log).
pub fn encode_ticket(invitation: &TrustInvitation) -> Result<String, PairingError> {
    let json = serde_json::to_vec(invitation)?;
    Ok(format!("pharos-trust1:{}", b64(&json)))
}

pub fn decode_ticket(ticket: &str) -> Result<TrustInvitation, PairingError> {
    let rest = ticket
        .strip_prefix("pharos-trust1:")
        .ok_or_else(|| PairingError::Invalid("ticket prefix".into()))?;
    let json = decode_b64(rest)?;
    Ok(serde_json::from_slice(&json)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invite_accept_roundtrip() {
        let inviter = SigningKey::generate(&mut rand::rngs::OsRng);
        let accepter = SigningKey::generate(&mut rand::rngs::OsRng);
        let invitation = issue_invitation(
            &inviter,
            IssueInvitationArgs {
                trust_group_id: "tg-1",
                membership_epoch: 1,
                inviter_device_id: "dev-inviter",
                inviter_endpoint_id: "endpoint-inviter",
                inviter_address_ticket: "ticket-inviter",
                inviter_roles: vec!["controller".into(), "host".into()],
                requested_roles: vec!["host".into(), "replica".into()],
                lifetime_ms: 60_000,
            },
        )
        .unwrap();
        let ticket = encode_ticket(&invitation).unwrap();
        let parsed = decode_ticket(&ticket).unwrap();
        assert_eq!(parsed.trust_group_id, "tg-1");
        let acceptance = accept_invitation(
            &parsed,
            &accepter,
            "dev-accepter",
            "endpoint-accepter",
            vec!["host".into(), "replica".into()],
        )
        .unwrap();
        verify_acceptance(&parsed, &acceptance).unwrap();
    }
}
