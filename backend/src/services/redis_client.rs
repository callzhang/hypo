use anyhow::Result;
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use rand::Rng;
use redis::{aio::ConnectionManager, Client};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::Mutex;
use tracing::debug;

use crate::services::metrics::{get_metrics, Metrics};

#[derive(Debug, thiserror::Error)]
pub enum PairingCodeError {
    #[error("pairing code not found")]
    NotFound,
    #[error("pairing code expired")]
    Expired,
    #[error("pairing code already claimed")]
    AlreadyClaimed,
    #[error("pairing code not yet claimed")]
    NotClaimed,
    #[error("pairing challenge not available")]
    ChallengeNotAvailable,
    #[error("pairing acknowledgement not available")]
    AckNotAvailable,
    #[error("unable to allocate unique pairing code")]
    AllocationFailed,
    #[error(transparent)]
    Redis(#[from] redis::RedisError),
    #[error(transparent)]
    Serialization(#[from] serde_json::Error),
}

impl PairingCodeError {
    fn status_code(&self) -> actix_web::http::StatusCode {
        use actix_web::http::StatusCode;
        match self {
            PairingCodeError::NotFound => StatusCode::NOT_FOUND,
            PairingCodeError::Expired => StatusCode::GONE,
            PairingCodeError::AlreadyClaimed => StatusCode::CONFLICT,
            PairingCodeError::NotClaimed => StatusCode::BAD_REQUEST,
            PairingCodeError::ChallengeNotAvailable => StatusCode::NOT_FOUND,
            PairingCodeError::AckNotAvailable => StatusCode::NOT_FOUND,
            PairingCodeError::AllocationFailed => StatusCode::SERVICE_UNAVAILABLE,
            PairingCodeError::Redis(_) | PairingCodeError::Serialization(_) => {
                StatusCode::INTERNAL_SERVER_ERROR
            }
        }
    }
}

impl actix_web::ResponseError for PairingCodeError {
    fn status_code(&self) -> actix_web::http::StatusCode {
        PairingCodeError::status_code(self)
    }

    fn error_response(&self) -> actix_web::HttpResponse {
        actix_web::HttpResponse::build(self.status_code())
            .json(serde_json::json!({ "error": self.to_string() }))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairingCodeEntry {
    pub code: String,
    #[serde(rename = "initiator_device_id")]
    pub initiator_device_id: String,
    #[serde(rename = "initiator_device_name")]
    pub initiator_device_name: String,
    #[serde(rename = "initiator_public_key")]
    pub initiator_public_key: String,
    pub issued_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    #[serde(rename = "responder_device_id")]
    pub responder_device_id: Option<String>,
    #[serde(rename = "responder_device_name")]
    pub responder_device_name: Option<String>,
    #[serde(rename = "responder_public_key")]
    pub responder_public_key: Option<String>,
    pub challenge_json: Option<String>,
    pub ack_json: Option<String>,
}

impl PairingCodeEntry {
    fn redis_key(code: &str) -> String {
        format!("pairing:code:{}", code)
    }

    fn ttl_seconds(&self) -> Result<u64, PairingCodeError> {
        let now = Utc::now();
        if self.expires_at <= now {
            return Err(PairingCodeError::Expired);
        }
        let remaining = self
            .expires_at
            .signed_duration_since(now)
            .num_seconds()
            .max(1);
        Ok(remaining as u64)
    }
}

/// Stand-in for Redis when there is none.
///
/// A key/value map with expiry, which is all this client asks of Redis:
/// device -> connection mappings and pairing entries, every one of them with a
/// TTL. Single process only, so it is right for local development and wrong
/// for more than one relay instance — which is why it is opt-in.
#[derive(Default)]
pub struct MemoryStore {
    entries: HashMap<String, (String, Option<SystemTime>)>,
}

impl MemoryStore {
    fn get(&mut self, key: &str) -> Option<String> {
        match self.entries.get(key) {
            Some((value, expiry)) => {
                if expiry.is_some_and(|at| SystemTime::now() >= at) {
                    self.entries.remove(key);
                    None
                } else {
                    Some(value.clone())
                }
            }
            None => None,
        }
    }

    fn set_ex(&mut self, key: &str, value: &str, ttl_secs: u64) {
        let expiry = SystemTime::now().checked_add(Duration::from_secs(ttl_secs));
        self.entries.insert(key.to_string(), (value.to_string(), expiry));
    }

    /// SET NX: stores only when the key is free, mirroring the allocation retry
    /// that pairing codes rely on to avoid handing the same code to two people.
    fn set_nx_ex(&mut self, key: &str, value: &str, ttl_secs: u64) -> bool {
        if self.get(key).is_some() {
            return false;
        }
        self.set_ex(key, value, ttl_secs);
        true
    }

    fn del(&mut self, key: &str) {
        self.entries.remove(key);
    }
}

#[derive(Clone)]
pub struct RedisClient {
    /// None when running against the in-memory store. Every Redis path returns
    /// before reaching it in that case.
    manager: Option<ConnectionManager>,
    /// Set only in memory mode. See MemoryStore for why this exists and why it
    /// is opt-in.
    memory: Option<Arc<Mutex<MemoryStore>>>,
    /// Held from construction so counting an operation costs an atomic add.
    /// get_metrics() takes an async read lock, which is not something to do on
    /// every Redis call; main initialises metrics before building this, so the
    /// handle is there to take once.
    metrics: Option<Metrics>,
}

impl RedisClient {
    pub async fn new(redis_url: &str) -> Result<Self> {
        let client = Client::open(redis_url)?;
        let manager = ConnectionManager::new(client).await?;
        let metrics = get_metrics().await;

        Ok(Self { manager: Some(manager), memory: None, metrics })
    }

    /// A client backed by a process-local map instead of Redis.
    ///
    /// For running the relay on a machine with no Redis. Sessions and pairing
    /// entries live in this process only, so two instances would not see each
    /// other's devices — main gates this behind an environment variable so a
    /// deployment cannot fall into it by accident when Redis is merely down.
    pub async fn new_in_memory() -> Self {
        Self {
            manager: None,
            memory: Some(Arc::new(Mutex::new(MemoryStore::default()))),
            metrics: get_metrics().await,
        }
    }

    /// Counted here rather than at the call sites: every operation goes through
    /// one of the methods below, so a new caller cannot forget to count itself.
    /// increment_redis_ops had no callers at all before this, so /status
    /// reported zero Redis operations no matter how much traffic there was.
    fn note_op(&self) {
        if let Some(m) = &self.metrics {
            m.increment_redis_ops();
        }
    }

    pub async fn register_device_batch(&mut self, registrations: &[(String, String)]) -> Result<()> {
        self.note_op();
        if let Some(mem) = &self.memory {
            let mut mem = mem.lock().await;
            for (device_id, connection_id) in registrations {
                mem.set_ex(&format!("device:{}", device_id), connection_id, 3600);
                mem.set_ex(&format!("conn:{}", connection_id), device_id, 3600);
            }
            return Ok(());
        }
        use redis::Pipeline;
        
        debug!("Registering {} devices in batch", registrations.len());
        
        let mut pipe = Pipeline::new();
        for (device_id, connection_id) in registrations {
            // device:<uuid> -> connection_id (TTL: 1 hour)
            pipe.set_ex(format!("device:{}", device_id), connection_id, 3600);
            // conn:<connection_id> -> device_id (TTL: 1 hour)
            pipe.set_ex(format!("conn:{}", connection_id), device_id, 3600);
        }
        
        let _: () = pipe.query_async(self.manager.as_mut().expect("redis backend present")).await?;
        Ok(())
    }

    pub async fn register_device(&mut self, device_id: &str, connection_id: &str) -> Result<()> {
        self.note_op();
        if let Some(mem) = &self.memory {
            let mut mem = mem.lock().await;
            mem.set_ex(&format!("device:{}", device_id), connection_id, 3600);
            mem.set_ex(&format!("conn:{}", connection_id), device_id, 3600);
            return Ok(());
        }
        use redis::Pipeline;

        debug!("Registering device {} with connection {}", device_id, connection_id);

        // Use pipeline for atomic registration
        let mut pipe = Pipeline::new();
        pipe.set_ex(format!("device:{}", device_id), connection_id, 3600)
            .set_ex(format!("conn:{}", connection_id), device_id, 3600);
        
        let _: () = pipe.query_async(self.manager.as_mut().expect("redis backend present")).await?;
        Ok(())
    }

    pub async fn unregister_device(&mut self, device_id: &str) -> Result<()> {
        self.note_op();
        if let Some(mem) = &self.memory {
            let mut mem = mem.lock().await;
            if let Some(conn_id) = mem.get(&format!("device:{}", device_id)) {
                mem.del(&format!("conn:{}", conn_id));
            }
            mem.del(&format!("device:{}", device_id));
            return Ok(());
        }
        use redis::{AsyncCommands, Pipeline};

        debug!("Unregistering device {}", device_id);

        // Get connection ID first
        let conn_id: Option<String> = self.manager.as_mut().expect("redis backend present").get(format!("device:{}", device_id)).await?;

        if let Some(conn_id) = conn_id {
            // Use pipeline for atomic cleanup
            let mut pipe = Pipeline::new();
            pipe.del(format!("device:{}", device_id))
                .del(format!("conn:{}", conn_id));
            
            let _: () = pipe.query_async(self.manager.as_mut().expect("redis backend present")).await?;
        }

        Ok(())
    }

    pub async fn unregister_devices_batch(&mut self, device_ids: &[String]) -> Result<()> {
        self.note_op();
        if let Some(mem) = &self.memory {
            let mut mem = mem.lock().await;
            for device_id in device_ids {
                if let Some(conn_id) = mem.get(&format!("device:{}", device_id)) {
                    mem.del(&format!("conn:{}", conn_id));
                }
                mem.del(&format!("device:{}", device_id));
            }
            return Ok(());
        }
        use redis::Pipeline;

        if device_ids.is_empty() {
            return Ok(());
        }

        debug!("Batch unregistering {} devices", device_ids.len());

        // Get all connection IDs first
        let mut pipe = Pipeline::new();
        for device_id in device_ids {
            pipe.get(format!("device:{}", device_id));
        }
        
        let conn_ids: Vec<Option<String>> = pipe.query_async(self.manager.as_mut().expect("redis backend present")).await?;

        // Delete all mappings
        let mut delete_pipe = Pipeline::new();
        for (device_id, conn_id) in device_ids.iter().zip(conn_ids.iter()) {
            delete_pipe.del(format!("device:{}", device_id));
            if let Some(conn_id) = conn_id {
                delete_pipe.del(format!("conn:{}", conn_id));
            }
        }
        
        let _: () = delete_pipe.query_async(self.manager.as_mut().expect("redis backend present")).await?;
        Ok(())
    }

    pub async fn get_device_connection(&mut self, device_id: &str) -> Result<Option<String>> {
        self.note_op();
        if let Some(mem) = &self.memory {
            return Ok(mem.lock().await.get(&format!("device:{}", device_id)));
        }
        use redis::AsyncCommands;

        let conn_id: Option<String> = self.manager.as_mut().expect("redis backend present").get(format!("device:{}", device_id)).await?;

        Ok(conn_id)
    }

    pub async fn create_pairing_code(
        &mut self,
        initiator_device_id: &str,
        initiator_device_name: &str,
        initiator_public_key: &str,
        ttl: Duration,
    ) -> Result<PairingCodeEntry, PairingCodeError> {
        self.note_op();
        let ttl_secs = ttl.as_secs().max(1);
        let issued_at = Utc::now();
        let expires_at = issued_at
            + ChronoDuration::from_std(Duration::from_secs(ttl_secs))
                .unwrap_or_else(|_| ChronoDuration::seconds(ttl_secs as i64));
        let mut rng = rand::thread_rng();

        for _ in 0..5 {
            let code = format!("{:06}", rng.gen_range(0..1_000_000));
            let entry = PairingCodeEntry {
                code: code.clone(),
                initiator_device_id: initiator_device_id.to_string(),
                initiator_device_name: initiator_device_name.to_string(),
                initiator_public_key: initiator_public_key.to_string(),
                issued_at,
                expires_at,
                responder_device_id: None,
                responder_device_name: None,
                responder_public_key: None,
                challenge_json: None,
                ack_json: None,
            };

            let payload = serde_json::to_string(&entry)?;
            if let Some(mem) = &self.memory {
                let taken = mem.lock().await.set_nx_ex(
                    &PairingCodeEntry::redis_key(&code),
                    &payload,
                    ttl_secs,
                );
                if taken {
                    return Ok(entry);
                }
                continue;
            }
            let mut cmd = redis::cmd("SET");
            cmd.arg(PairingCodeEntry::redis_key(&code))
                .arg(payload)
                .arg("EX")
                .arg(ttl_secs)
                .arg("NX");
            let result: Option<String> = cmd.query_async(self.manager.as_mut().expect("redis backend present")).await?;
            if result.is_some() {
                return Ok(entry);
            }
        }

        Err(PairingCodeError::AllocationFailed)
    }

    pub async fn claim_pairing_code(
        &mut self,
        code: &str,
        responder_device_id: &str,
        responder_device_name: &str,
        responder_public_key: &str,
    ) -> Result<PairingCodeEntry, PairingCodeError> {
        self.note_op();
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        if entry.responder_device_id.is_some() {
            return Err(PairingCodeError::AlreadyClaimed);
        }

        entry.responder_device_id = Some(responder_device_id.to_string());
        entry.responder_device_name = Some(responder_device_name.to_string());
        entry.responder_public_key = Some(responder_public_key.to_string());
        self.save_pairing_entry(&entry).await?;
        Ok(entry)
    }

    pub async fn store_pairing_challenge(
        &mut self,
        code: &str,
        responder_device_id: &str,
        challenge_json: &str,
    ) -> Result<(), PairingCodeError> {
        self.note_op();
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        match entry.responder_device_id.as_deref() {
            Some(id) if id == responder_device_id => {
                entry.challenge_json = Some(challenge_json.to_string());
                self.save_pairing_entry(&entry).await?;
                Ok(())
            }
            Some(_) => Err(PairingCodeError::AlreadyClaimed),
            None => Err(PairingCodeError::NotClaimed),
        }
    }

    pub async fn consume_pairing_challenge(
        &mut self,
        code: &str,
        initiator_device_id: &str,
    ) -> Result<String, PairingCodeError> {
        self.note_op();
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        if entry.initiator_device_id != initiator_device_id {
            return Err(PairingCodeError::NotFound);
        }

        let challenge = entry
            .challenge_json
            .take()
            .ok_or(PairingCodeError::ChallengeNotAvailable)?;
        self.save_pairing_entry(&entry).await?;
        Ok(challenge)
    }

    pub async fn store_pairing_ack(
        &mut self,
        code: &str,
        initiator_device_id: &str,
        ack_json: &str,
    ) -> Result<(), PairingCodeError> {
        self.note_op();
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        if entry.initiator_device_id != initiator_device_id {
            return Err(PairingCodeError::NotFound);
        }

        entry.ack_json = Some(ack_json.to_string());
        self.save_pairing_entry(&entry).await?;
        Ok(())
    }

    pub async fn consume_pairing_ack(
        &mut self,
        code: &str,
        responder_device_id: &str,
    ) -> Result<String, PairingCodeError> {
        self.note_op();
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        match entry.responder_device_id.as_deref() {
            Some(id) if id == responder_device_id => {
                let ack = entry
                    .ack_json
                    .take()
                    .ok_or(PairingCodeError::AckNotAvailable)?;
                self.delete_pairing_entry(code).await?;
                Ok(ack)
            }
            Some(_) => Err(PairingCodeError::AlreadyClaimed),
            None => Err(PairingCodeError::NotClaimed),
        }
    }

    async fn load_pairing_entry(
        &mut self,
        code: &str,
    ) -> Result<Option<PairingCodeEntry>, PairingCodeError> {
        if let Some(mem) = &self.memory {
            let key = PairingCodeEntry::redis_key(code);
            let mut mem = mem.lock().await;
            return match mem.get(&key) {
                Some(json) => {
                    let entry: PairingCodeEntry = serde_json::from_str(&json)?;
                    if entry.expires_at <= Utc::now() {
                        mem.del(&key);
                        Ok(None)
                    } else {
                        Ok(Some(entry))
                    }
                }
                None => Ok(None),
            };
        }
        use redis::AsyncCommands;

        let key = PairingCodeEntry::redis_key(code);
        let value: Option<String> = self.manager.as_mut().expect("redis backend present").get(&key).await?;
        if let Some(json) = value {
            let entry: PairingCodeEntry = serde_json::from_str(&json)?;
            if entry.expires_at <= Utc::now() {
                let _: () = self.manager.as_mut().expect("redis backend present").del(key).await?;
                return Ok(None);
            }
            Ok(Some(entry))
        } else {
            Ok(None)
        }
    }

    async fn save_pairing_entry(
        &mut self,
        entry: &PairingCodeEntry,
    ) -> Result<(), PairingCodeError> {
        if let Some(mem) = &self.memory {
            let ttl = entry.ttl_seconds()?;
            let key = PairingCodeEntry::redis_key(&entry.code);
            let payload = serde_json::to_string(entry)?;
            mem.lock().await.set_ex(&key, &payload, ttl);
            return Ok(());
        }
        use redis::AsyncCommands;

        let ttl = entry.ttl_seconds()?;
        let key = PairingCodeEntry::redis_key(&entry.code);
        let payload = serde_json::to_string(entry)?;
        self.manager.as_mut().expect("redis backend present").set_ex::<_, _, ()>(key, payload, ttl).await?;
        Ok(())
    }

    async fn delete_pairing_entry(&mut self, code: &str) -> Result<(), PairingCodeError> {
        if let Some(mem) = &self.memory {
            mem.lock().await.del(&PairingCodeEntry::redis_key(code));
            return Ok(());
        }
        use redis::AsyncCommands;

        let key = PairingCodeEntry::redis_key(code);
        let _: () = self.manager.as_mut().expect("redis backend present").del(key).await?;
        Ok(())
    }
}
