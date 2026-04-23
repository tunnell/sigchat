// Prekey generation for the secondary-device link flow.
// Produces the four prekey JSON objects required by PUT /v1/devices/link.
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![deny(clippy::panic)]

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use libsignal_protocol::{KeyPair as DjbKeyPair, PrivateKey, kem};
use rand::{RngCore, TryRngCore as _, rngs::OsRng};
use std::io::{Error, ErrorKind};

/// Medium.MAX_VALUE (2^24 - 1) — the upper bound for Signal's prekey IDs.
const MEDIUM_MAX: u32 = 0x00FF_FFFF;

pub struct SignedPreKeyJson {
    pub key_id: u32,
    pub public_key_b64url: String,
    pub signature_b64url: String,
}

pub struct KyberPreKeyJson {
    pub key_id: u32,
    pub public_key_b64url: String,
    pub signature_b64url: String,
}

pub struct Prekeys {
    pub aci_signed: SignedPreKeyJson,
    pub pni_signed: SignedPreKeyJson,
    pub aci_kyber_last_resort: KyberPreKeyJson,
    pub pni_kyber_last_resort: KyberPreKeyJson,
}

/// Generate ACI+PNI signed and Kyber last-resort prekeys, signed by the
/// corresponding identity private key. All four JSON values are encoded as
/// URL-safe no-padding base64 per the Signal spec.
pub fn generate_prekeys(
    aci_identity_private: &PrivateKey,
    pni_identity_private: &PrivateKey,
) -> Result<Prekeys, Error> {
    Ok(Prekeys {
        aci_signed: generate_signed_prekey(aci_identity_private, "aci")?,
        pni_signed: generate_signed_prekey(pni_identity_private, "pni")?,
        aci_kyber_last_resort: generate_kyber_last_resort(aci_identity_private, "aci")?,
        pni_kyber_last_resort: generate_kyber_last_resort(pni_identity_private, "pni")?,
    })
}

fn random_prekey_id() -> Result<u32, Error> {
    let mut rng = OsRng.unwrap_err();
    Ok((rng.next_u32() % MEDIUM_MAX) + 1)
}

/// X25519 signed prekey: fresh Curve25519 keypair whose serialized public key
/// is signed (Ed25519 on Curve25519) by the identity private key.
fn generate_signed_prekey(
    identity_private: &PrivateKey,
    label: &str,
) -> Result<SignedPreKeyJson, Error> {
    let mut rng = OsRng.unwrap_err();
    let keypair = DjbKeyPair::generate(&mut rng);
    let public_serialized = keypair.public_key.serialize(); // 33 bytes: 0x05 prefix + 32 key
    let signature = identity_private
        .calculate_signature(&public_serialized, &mut rng)
        .map_err(|e| {
            log::error!("{label} signed prekey signing failed: {e:?}");
            Error::new(ErrorKind::Other, "signed prekey signing failed")
        })?;

    let identity_public = identity_private.public_key().map_err(|e| {
        log::error!("{label} identity public derivation failed: {e:?}");
        Error::new(ErrorKind::Other, "identity public key derivation failed")
    })?;
    if !identity_public.verify_signature(&public_serialized, &signature) {
        log::error!("{label} signed prekey self-verification failed — aborting link");
        return Err(Error::new(
            ErrorKind::InvalidData,
            "signed prekey self-verification failed",
        ));
    }

    Ok(SignedPreKeyJson {
        key_id: random_prekey_id()?,
        public_key_b64url: URL_SAFE_NO_PAD.encode(&public_serialized),
        signature_b64url: URL_SAFE_NO_PAD.encode(&signature),
    })
}

/// Kyber1024 last-resort prekey: fresh KEM keypair whose serialized public key
/// is signed (Ed25519) by the identity private key.
fn generate_kyber_last_resort(
    identity_private: &PrivateKey,
    label: &str,
) -> Result<KyberPreKeyJson, Error> {
    let mut rng = OsRng.unwrap_err();
    let kem_keypair = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut rng);
    let public_serialized = kem_keypair.public_key.serialize(); // Box<[u8]> with 0x08 prefix
    let signature = identity_private
        .calculate_signature(&public_serialized, &mut rng)
        .map_err(|e| {
            log::error!("{label} kyber last-resort signing failed: {e:?}");
            Error::new(ErrorKind::Other, "kyber last-resort signing failed")
        })?;

    let identity_public = identity_private.public_key().map_err(|e| {
        log::error!("{label} identity public derivation failed: {e:?}");
        Error::new(ErrorKind::Other, "identity public key derivation failed")
    })?;
    if !identity_public.verify_signature(&public_serialized, &signature) {
        log::error!("{label} kyber prekey self-verification failed — aborting link");
        return Err(Error::new(
            ErrorKind::InvalidData,
            "kyber prekey self-verification failed",
        ));
    }

    Ok(KyberPreKeyJson {
        key_id: random_prekey_id()?,
        public_key_b64url: URL_SAFE_NO_PAD.encode(&public_serialized),
        signature_b64url: URL_SAFE_NO_PAD.encode(&signature),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use libsignal_protocol::IdentityKeyPair;

    #[test]
    fn generate_prekeys_emits_four_with_expected_shapes() {
        let mut rng = OsRng.unwrap_err();
        let aci = IdentityKeyPair::generate(&mut rng);
        let pni = IdentityKeyPair::generate(&mut rng);

        let prekeys = generate_prekeys(aci.private_key(), pni.private_key())
            .expect("generate_prekeys should succeed with fresh identity keys");

        // X25519 serialized public key = 33 bytes -> 44 URL_SAFE_NO_PAD chars.
        // Ed25519 signature = 64 bytes -> 86 URL_SAFE_NO_PAD chars.
        assert_eq!(prekeys.aci_signed.public_key_b64url.len(), 44);
        assert_eq!(prekeys.aci_signed.signature_b64url.len(), 86);
        assert_eq!(prekeys.pni_signed.public_key_b64url.len(), 44);
        assert_eq!(prekeys.pni_signed.signature_b64url.len(), 86);

        // Kyber1024 serialized public key is much larger — just assert non-empty.
        assert!(!prekeys.aci_kyber_last_resort.public_key_b64url.is_empty());
        assert_eq!(prekeys.aci_kyber_last_resort.signature_b64url.len(), 86);
        assert!(!prekeys.pni_kyber_last_resort.public_key_b64url.is_empty());
        assert_eq!(prekeys.pni_kyber_last_resort.signature_b64url.len(), 86);

        // Key IDs are within Medium range.
        for id in [
            prekeys.aci_signed.key_id,
            prekeys.pni_signed.key_id,
            prekeys.aci_kyber_last_resort.key_id,
            prekeys.pni_kyber_last_resort.key_id,
        ] {
            assert!(id >= 1 && id <= MEDIUM_MAX);
        }
    }
}
