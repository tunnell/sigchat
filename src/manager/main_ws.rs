//! Authenticated main WebSocket worker for Signal message receive.
//!
//! Connects to wss://{host}/v1/websocket/?login={aci}.{device_id}&password={password},
//! decrypts incoming envelopes using the Phase 2 pddb-backed stores, parses the
//! decrypted Content proto, and delivers DataMessage text to the Chat UI via IPC.
//!
//! Lifecycle: spawned by `Manager::start_receive()`; runs until the connection
//! drops or an unrecoverable error occurs. Fire-and-forget — no IPC needed back.

#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![deny(clippy::panic)]

use std::convert::TryFrom as _;
use futures::executor::block_on;
use libsignal_protocol::{
    DeviceId, PreKeySignalMessage, ProtocolAddress, SignalMessage,
    message_decrypt_prekey, message_decrypt_signal,
};
use prost::Message as ProstMessage;
use rand::TryRngCore as _;
use std::io;
use std::thread;
use std::time::Duration;
use ticktimer_server::Ticktimer;
use tungstenite::Message;
use xous::CID;

use crate::manager::signal_ws::SignalWS;
use crate::manager::stores::{
    PddbIdentityStore, PddbKyberPreKeyStore, PddbPreKeyStore, PddbSessionStore,
    PddbSignedPreKeyStore,
};

const KEEPALIVE_MS: u64 = 25_000;
const READ_TIMEOUT_MS: u64 = 500;

const ACCOUNT_DICT: &'static str = "sigchat.account";
const IDENTITY_DICT: &'static str = "sigchat.identity";
const PREKEY_DICT: &'static str = "sigchat.prekey";
const SIGNED_PREKEY_DICT: &'static str = "sigchat.signed_prekey";
const KYBER_PREKEY_DICT: &'static str = "sigchat.kyber_prekey";
const SESSION_DICT: &'static str = "sigchat.session";

const WS_TYPE_REQUEST: i32 = 1;
const WS_TYPE_RESPONSE: i32 = 2;

// Envelope.type values from signalservice.proto
const ENVELOPE_CIPHERTEXT: i32 = 1;
const ENVELOPE_PREKEY_BUNDLE: i32 = 3;

// ---- Inline prost message definitions ---------------------------------------
// Mirror SignalService.proto and WebSocketProtos.proto wire types.

#[derive(prost::Message)]
struct WsRequestProto {
    #[prost(string, optional, tag = "1")]
    verb: Option<String>,
    #[prost(string, optional, tag = "2")]
    path: Option<String>,
    #[prost(bytes = "vec", optional, tag = "3")]
    body: Option<Vec<u8>>,
    #[prost(uint64, optional, tag = "4")]
    id: Option<u64>,
    #[prost(string, repeated, tag = "5")]
    headers: Vec<String>,
}

#[derive(prost::Message)]
struct WsResponseProto {
    #[prost(uint64, optional, tag = "1")]
    id: Option<u64>,
    #[prost(uint32, optional, tag = "2")]
    status: Option<u32>,
    #[prost(string, optional, tag = "3")]
    message: Option<String>,
    #[prost(bytes = "vec", optional, tag = "4")]
    body: Option<Vec<u8>>,
    #[prost(string, repeated, tag = "5")]
    headers: Vec<String>,
}

#[derive(prost::Message)]
struct WsMessageProto {
    #[prost(int32, optional, tag = "1")]
    r#type: Option<i32>,
    #[prost(message, optional, tag = "2")]
    request: Option<WsRequestProto>,
    #[prost(message, optional, tag = "3")]
    response: Option<WsResponseProto>,
}

// Signal Envelope (signalservice.proto)
#[derive(prost::Message)]
struct EnvelopeProto {
    // 1=CIPHERTEXT, 3=PREKEY_BUNDLE, 5=RECEIPT, 6=UNIDENTIFIED_SENDER
    #[prost(int32, optional, tag = "1")]
    r#type: Option<i32>,
    // sourceServiceId: sender's ACI UUID string
    #[prost(string, optional, tag = "2")]
    source_service_id: Option<String>,
    #[prost(uint32, optional, tag = "7")]
    source_device: Option<u32>,
    #[prost(uint64, optional, tag = "5")]
    server_timestamp: Option<u64>,
    #[prost(bytes = "vec", optional, tag = "8")]
    content: Option<Vec<u8>>,
}

// Content / DataMessage (signalservice.proto)
// Only the fields needed for Phase 4 text delivery.
#[derive(prost::Message)]
struct DataMessageProto {
    // body: plain-text content of the message
    #[prost(string, optional, tag = "1")]
    body: Option<String>,
    // timestamp: milliseconds since epoch the sender stamped the message
    #[prost(uint64, optional, tag = "5")]
    timestamp: Option<u64>,
}

#[derive(prost::Message)]
struct ContentProto {
    #[prost(message, optional, tag = "1")]
    data_message: Option<DataMessageProto>,
    // Other sub-messages (sync, call, receipt…) are present on the wire but
    // opaque for Phase 4 — prost silently ignores unknown fields.
}

// ---- Public interface -------------------------------------------------------

pub struct MainWsWorker {
    thread: thread::JoinHandle<()>,
}

impl MainWsWorker {
    /// Spawn the receive worker. `chat_cid` is the CID of the Chat UI server;
    /// the worker calls PostAdd on it whenever a DataMessage arrives.
    /// Returns immediately; the worker runs until the connection drops.
    pub fn spawn(
        aci_service_id: String,
        device_id: u32,
        password: String,
        host: String,
        chat_cid: CID,
    ) -> io::Result<Self> {
        let t = thread::Builder::new()
            .name("sigchat-main-ws".into())
            .spawn(move || worker_loop(aci_service_id, device_id, password, host, chat_cid))
            .map_err(|e| io::Error::other(format!("main_ws spawn: {e}")))?;
        Ok(Self { thread: t })
    }

    /// Block until the worker exits. Provided for clean shutdown; callers
    /// normally discard the handle and let the worker run freely.
    #[allow(dead_code)]
    pub fn join(self) {
        let _ = self.thread.join();
    }
}

// ---- Worker -----------------------------------------------------------------

fn worker_loop(
    aci_service_id: String,
    device_id: u32,
    password: String,
    host: String,
    chat_cid: CID,
) {
    log::info!("main_ws: connecting to {host}");

    if device_id == 0 || device_id > 127 {
        log::error!("main_ws: device_id {device_id} out of valid Signal range (1..=127)");
        return;
    }
    let local_device = match DeviceId::new(device_id as u8) {
        Ok(d) => d,
        Err(_) => return,
    };
    let local_addr = ProtocolAddress::new(aci_service_id.clone(), local_device);

    let mut ws = match SignalWS::new_message(&host, &aci_service_id, device_id, &password) {
        Ok(ws) => ws,
        Err(e) => {
            log::error!("main_ws: connect failed: {e}");
            return;
        }
    };
    log::info!("main_ws: authenticated websocket established");

    if let Err(e) = ws.set_read_timeout(Some(Duration::from_millis(READ_TIMEOUT_MS))) {
        log::warn!("main_ws: set_read_timeout failed: {e}");
    }

    let tt = match Ticktimer::new() {
        Ok(t) => t,
        Err(e) => {
            log::error!("main_ws: Ticktimer::new failed: {e:?}");
            ws.close();
            return;
        }
    };

    let mut last_ping_ms = tt.elapsed_ms();

    loop {
        // (1) Application-layer keepalive Ping.
        if tt.elapsed_ms().saturating_sub(last_ping_ms) >= KEEPALIVE_MS {
            match ws.send(Message::Ping(Vec::new())) {
                Ok(()) => {
                    last_ping_ms = tt.elapsed_ms();
                    log::debug!("main_ws: sent keepalive Ping");
                }
                Err(e) => {
                    log::warn!("main_ws: keepalive Ping failed: {e}");
                    break;
                }
            }
        }

        // (2) Read next WebSocket frame (500ms timeout drives the cycle).
        let raw = match ws.read() {
            Ok(Message::Binary(b)) => b,
            Ok(Message::Ping(_)) => {
                log::debug!("main_ws: got server Ping");
                continue;
            }
            Ok(Message::Pong(_)) => {
                log::debug!("main_ws: got server Pong");
                continue;
            }
            Ok(Message::Close(c)) => {
                log::info!("main_ws: server closed connection: {c:?}");
                break;
            }
            Ok(_) => continue,
            Err(e) if is_timeout(&e) => continue,
            Err(e) => {
                log::warn!("main_ws: read error: {e}");
                break;
            }
        };

        // (3) Decode WebSocketMessage wrapper.
        let ws_msg = match WsMessageProto::decode(raw.as_slice()) {
            Ok(m) => m,
            Err(e) => {
                log::warn!("main_ws: WebSocketMessage decode failed: {e}");
                continue;
            }
        };

        match ws_msg.r#type {
            Some(WS_TYPE_REQUEST) => {
                if let Some(req) = ws_msg.request {
                    handle_request(&mut ws, req, &local_addr, chat_cid);
                }
            }
            Some(WS_TYPE_RESPONSE) => {
                // ACKs from server for our keep-alive requests — ignore.
            }
            other => {
                log::debug!("main_ws: unhandled WsMessage type {other:?}");
            }
        }
    }

    log::info!("main_ws: worker loop exited; closing websocket");
    ws.close();
}

fn handle_request(
    ws: &mut SignalWS,
    req: WsRequestProto,
    local_addr: &ProtocolAddress,
    chat_cid: CID,
) {
    let id = req.id.unwrap_or(0);
    let verb = req.verb.as_deref().unwrap_or("");
    let path = req.path.as_deref().unwrap_or("");

    if verb == "PUT" && path == "/api/v1/message" {
        if let Some(body) = req.body {
            dispatch_envelope(body, local_addr, chat_cid);
        }
        send_ack(ws, id, 200);
    } else if verb == "PUT" && path == "/api/v1/queue/empty" {
        log::info!("main_ws: message queue drained");
        send_ack(ws, id, 200);
    } else {
        log::debug!("main_ws: server request {verb} {path} (id={id})");
        send_ack(ws, id, 200);
    }
}

fn send_ack(ws: &mut SignalWS, id: u64, status: u32) {
    let msg = WsMessageProto {
        r#type: Some(WS_TYPE_RESPONSE),
        request: None,
        response: Some(WsResponseProto {
            id: Some(id),
            status: Some(status),
            message: Some("OK".to_string()),
            body: None,
            headers: Vec::new(),
        }),
    };
    if let Err(e) = ws.send(Message::Binary(msg.encode_to_vec())) {
        log::warn!("main_ws: ACK send failed (id={id}): {e}");
    }
}

fn dispatch_envelope(body: Vec<u8>, local_addr: &ProtocolAddress, chat_cid: CID) {
    let envelope = match EnvelopeProto::decode(body.as_slice()) {
        Ok(e) => e,
        Err(e) => {
            log::warn!("main_ws: Envelope proto decode failed: {e}");
            return;
        }
    };

    let source_id = envelope.source_service_id.clone().unwrap_or_default();
    let source_dev = envelope.source_device.unwrap_or(1);
    let env_type = envelope.r#type.unwrap_or(0);
    let ts = envelope.server_timestamp.unwrap_or(0);

    log::info!("main_ws: envelope type={env_type} from={source_id}/{source_dev} ts={ts}");

    let content = match envelope.content {
        Some(c) => c,
        None => {
            log::debug!("main_ws: envelope type={env_type} has no content bytes, skipping");
            return;
        }
    };

    if source_dev == 0 || source_dev > 127 {
        log::warn!("main_ws: source_device {source_dev} out of valid range (1..=127), skipping");
        return;
    }
    let sender_device = match DeviceId::new(source_dev as u8) {
        Ok(d) => d,
        Err(_) => return,
    };
    let remote_addr = ProtocolAddress::new(source_id, sender_device);

    // Create one pddb handle per store (each takes ownership).
    let pddb_id = pddb::Pddb::new(); pddb_id.try_mount();
    let pddb_pk = pddb::Pddb::new(); pddb_pk.try_mount();
    let pddb_spk = pddb::Pddb::new(); pddb_spk.try_mount();
    let pddb_kpk = pddb::Pddb::new(); pddb_kpk.try_mount();
    let pddb_ses = pddb::Pddb::new(); pddb_ses.try_mount();

    let mut identity_store = PddbIdentityStore::new(pddb_id, ACCOUNT_DICT, IDENTITY_DICT);
    let mut pre_key_store = PddbPreKeyStore::new(pddb_pk, PREKEY_DICT);
    let signed_pre_key_store = PddbSignedPreKeyStore::new(pddb_spk, SIGNED_PREKEY_DICT);
    let mut kyber_pre_key_store = PddbKyberPreKeyStore::new(pddb_kpk, KYBER_PREKEY_DICT);
    let mut session_store = PddbSessionStore::new(pddb_ses, SESSION_DICT);
    let mut rng = rand::rngs::OsRng.unwrap_err();

    let plaintext = match env_type {
        ENVELOPE_PREKEY_BUNDLE => {
            let prekey_msg = match PreKeySignalMessage::try_from(content.as_ref()) {
                Ok(m) => m,
                Err(e) => {
                    log::warn!("main_ws: PreKeySignalMessage parse failed: {e:?}");
                    return;
                }
            };
            match block_on(message_decrypt_prekey(
                &prekey_msg,
                &remote_addr,
                local_addr,
                &mut session_store,
                &mut identity_store,
                &mut pre_key_store,
                &signed_pre_key_store,
                &mut kyber_pre_key_store,
                &mut rng,
            )) {
                Ok(pt) => {
                    log::info!(
                        "main_ws: PREKEY_BUNDLE decrypted {} bytes from {}",
                        pt.len(), remote_addr.name()
                    );
                    pt
                }
                Err(e) => {
                    log::warn!("main_ws: PREKEY_BUNDLE decrypt failed from {}: {e:?}",
                        remote_addr.name());
                    return;
                }
            }
        }
        ENVELOPE_CIPHERTEXT => {
            let signal_msg = match SignalMessage::try_from(content.as_ref()) {
                Ok(m) => m,
                Err(e) => {
                    log::warn!("main_ws: SignalMessage parse failed: {e:?}");
                    return;
                }
            };
            match block_on(message_decrypt_signal(
                &signal_msg,
                &remote_addr,
                &mut session_store,
                &mut identity_store,
                &mut rng,
            )) {
                Ok(pt) => {
                    log::info!(
                        "main_ws: CIPHERTEXT decrypted {} bytes from {}",
                        pt.len(), remote_addr.name()
                    );
                    pt
                }
                Err(e) => {
                    log::warn!("main_ws: CIPHERTEXT decrypt failed from {}: {e:?}",
                        remote_addr.name());
                    return;
                }
            }
        }
        other => {
            log::debug!("main_ws: unhandled envelope type {other} from {}", remote_addr.name());
            return;
        }
    };

    deliver_content(plaintext, &remote_addr, ts, chat_cid);
}

/// Decode the decrypted Content proto and push any DataMessage text to the Chat UI.
fn deliver_content(plaintext: Vec<u8>, remote_addr: &ProtocolAddress, server_ts: u64, chat_cid: CID) {
    let content = match ContentProto::decode(plaintext.as_slice()) {
        Ok(c) => c,
        Err(e) => {
            log::warn!("main_ws: Content proto decode failed from {}: {e}", remote_addr.name());
            return;
        }
    };

    if let Some(dm) = content.data_message {
        let body = dm.body.unwrap_or_default();
        if body.is_empty() {
            log::debug!("main_ws: DataMessage with no body from {} (attachment/reaction?)",
                remote_addr.name());
            return;
        }
        // Use the sender-stamped timestamp when available; fall back to server_ts.
        let ts = dm.timestamp.unwrap_or(server_ts);
        cf_post_add(chat_cid, remote_addr.name(), ts, &body);
        log::info!(
            "main_ws: delivered {} chars from {} to chat UI",
            body.len(), remote_addr.name()
        );
    } else {
        log::debug!(
            "main_ws: Content from {} has no DataMessage (sync/call/receipt/etc.)",
            remote_addr.name()
        );
    }
}

fn cf_post_add(chat_cid: CID, author: &str, timestamp: u64, text: &str) {
    chat::cf_post_add(chat_cid, author, timestamp, text);
}

fn is_timeout(e: &tungstenite::Error) -> bool {
    if let tungstenite::Error::Io(io_err) = e {
        matches!(io_err.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut)
    } else {
        false
    }
}
