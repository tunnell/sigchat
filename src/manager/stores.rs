// PDDB-backed implementations of libsignal_protocol store traits.
// Phase 1: skeletons only — all methods return unimplemented!("phase 2").
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![deny(clippy::panic)]

use async_trait::async_trait;
use libsignal_protocol::{
    Direction, IdentityChange, IdentityKey, IdentityKeyPair, IdentityKeyStore,
    KyberPreKeyId, KyberPreKeyRecord, KyberPreKeyStore,
    PreKeyId, PreKeyRecord, PreKeyStore,
    ProtocolAddress, PublicKey, SignalProtocolError,
    SessionRecord, SessionStore,
    SignedPreKeyId, SignedPreKeyRecord, SignedPreKeyStore,
};

type SignalResult<T> = std::result::Result<T, SignalProtocolError>;

// ---------------------------------------------------------------------------
// PddbIdentityStore
// ---------------------------------------------------------------------------

pub struct PddbIdentityStore {
    pddb: pddb::Pddb,
    account_dict: &'static str,
    identity_dict: &'static str,
}

impl PddbIdentityStore {
    pub fn new(pddb: pddb::Pddb, account_dict: &'static str, identity_dict: &'static str) -> Self {
        Self { pddb, account_dict, identity_dict }
    }
}

#[async_trait(?Send)]
impl IdentityKeyStore for PddbIdentityStore {
    async fn get_identity_key_pair(&self) -> SignalResult<IdentityKeyPair> {
        unimplemented!("phase 2")
    }

    async fn get_local_registration_id(&self) -> SignalResult<u32> {
        unimplemented!("phase 2")
    }

    async fn save_identity(
        &mut self,
        address: &ProtocolAddress,
        identity: &IdentityKey,
    ) -> SignalResult<IdentityChange> {
        unimplemented!("phase 2")
    }

    async fn is_trusted_identity(
        &self,
        address: &ProtocolAddress,
        identity: &IdentityKey,
        direction: Direction,
    ) -> SignalResult<bool> {
        unimplemented!("phase 2")
    }

    async fn get_identity(&self, address: &ProtocolAddress) -> SignalResult<Option<IdentityKey>> {
        unimplemented!("phase 2")
    }
}

// ---------------------------------------------------------------------------
// PddbPreKeyStore
// ---------------------------------------------------------------------------

pub struct PddbPreKeyStore {
    pddb: pddb::Pddb,
    dict: &'static str,
}

impl PddbPreKeyStore {
    pub fn new(pddb: pddb::Pddb, dict: &'static str) -> Self {
        Self { pddb, dict }
    }
}

#[async_trait(?Send)]
impl PreKeyStore for PddbPreKeyStore {
    async fn get_pre_key(&self, prekey_id: PreKeyId) -> SignalResult<PreKeyRecord> {
        unimplemented!("phase 2")
    }

    async fn save_pre_key(&mut self, prekey_id: PreKeyId, record: &PreKeyRecord) -> SignalResult<()> {
        unimplemented!("phase 2")
    }

    async fn remove_pre_key(&mut self, prekey_id: PreKeyId) -> SignalResult<()> {
        unimplemented!("phase 2")
    }
}

// ---------------------------------------------------------------------------
// PddbSignedPreKeyStore
// ---------------------------------------------------------------------------

pub struct PddbSignedPreKeyStore {
    pddb: pddb::Pddb,
    dict: &'static str,
}

impl PddbSignedPreKeyStore {
    pub fn new(pddb: pddb::Pddb, dict: &'static str) -> Self {
        Self { pddb, dict }
    }
}

#[async_trait(?Send)]
impl SignedPreKeyStore for PddbSignedPreKeyStore {
    async fn get_signed_pre_key(
        &self,
        signed_prekey_id: SignedPreKeyId,
    ) -> SignalResult<SignedPreKeyRecord> {
        unimplemented!("phase 2")
    }

    async fn save_signed_pre_key(
        &mut self,
        signed_prekey_id: SignedPreKeyId,
        record: &SignedPreKeyRecord,
    ) -> SignalResult<()> {
        unimplemented!("phase 2")
    }
}

// ---------------------------------------------------------------------------
// PddbKyberPreKeyStore
// ---------------------------------------------------------------------------

pub struct PddbKyberPreKeyStore {
    pddb: pddb::Pddb,
    dict: &'static str,
}

impl PddbKyberPreKeyStore {
    pub fn new(pddb: pddb::Pddb, dict: &'static str) -> Self {
        Self { pddb, dict }
    }
}

#[async_trait(?Send)]
impl KyberPreKeyStore for PddbKyberPreKeyStore {
    async fn get_kyber_pre_key(&self, kyber_prekey_id: KyberPreKeyId) -> SignalResult<KyberPreKeyRecord> {
        unimplemented!("phase 2")
    }

    async fn save_kyber_pre_key(
        &mut self,
        kyber_prekey_id: KyberPreKeyId,
        record: &KyberPreKeyRecord,
    ) -> SignalResult<()> {
        unimplemented!("phase 2")
    }

    async fn mark_kyber_pre_key_used(
        &mut self,
        kyber_prekey_id: KyberPreKeyId,
        ec_prekey_id: SignedPreKeyId,
        base_key: &PublicKey,
    ) -> SignalResult<()> {
        unimplemented!("phase 2")
    }
}

// ---------------------------------------------------------------------------
// PddbSessionStore
// ---------------------------------------------------------------------------

pub struct PddbSessionStore {
    pddb: pddb::Pddb,
    dict: &'static str,
}

impl PddbSessionStore {
    pub fn new(pddb: pddb::Pddb, dict: &'static str) -> Self {
        Self { pddb, dict }
    }
}

#[async_trait(?Send)]
impl SessionStore for PddbSessionStore {
    async fn load_session(&self, address: &ProtocolAddress) -> SignalResult<Option<SessionRecord>> {
        unimplemented!("phase 2")
    }

    async fn store_session(
        &mut self,
        address: &ProtocolAddress,
        record: &SessionRecord,
    ) -> SignalResult<()> {
        unimplemented!("phase 2")
    }
}
