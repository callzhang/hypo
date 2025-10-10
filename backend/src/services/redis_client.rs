use anyhow::Result;
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use rand::Rng;
use redis::{aio::ConnectionManager, Client};
use serde::{Deserialize, Serialize};
use std::time::Duration;

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
    pub mac_device_id: String,
    pub mac_device_name: String,
    pub mac_public_key: String,
    pub issued_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub android_device_id: Option<String>,
    pub android_device_name: Option<String>,
    pub android_public_key: Option<String>,
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

#[derive(Clone)]
pub struct RedisClient {
    manager: ConnectionManager,
}

impl RedisClient {
    pub async fn new(redis_url: &str) -> Result<Self> {
        let client = Client::open(redis_url)?;
        let manager = ConnectionManager::new(client).await?;
        Ok(Self { manager })
    }

    pub async fn register_device(&mut self, device_id: &str, connection_id: &str) -> Result<()> {
        use redis::AsyncCommands;

        // device:<uuid> -> connection_id (TTL: 1 hour)
        self.manager
            .set_ex::<_, _, ()>(format!("device:{}", device_id), connection_id, 3600)
            .await?;

        // conn:<connection_id> -> device_id (TTL: 1 hour)
        self.manager
            .set_ex::<_, _, ()>(format!("conn:{}", connection_id), device_id, 3600)
            .await?;

        Ok(())
    }

    pub async fn unregister_device(&mut self, device_id: &str) -> Result<()> {
        use redis::AsyncCommands;

        // Get connection ID first
        let conn_id: Option<String> = self.manager.get(format!("device:{}", device_id)).await?;

        if let Some(conn_id) = conn_id {
            // Delete both mappings
            self.manager
                .del::<_, ()>(format!("device:{}", device_id))
                .await?;
            self.manager
                .del::<_, ()>(format!("conn:{}", conn_id))
                .await?;
        }

        Ok(())
    }

    pub async fn get_device_connection(&mut self, device_id: &str) -> Result<Option<String>> {
        use redis::AsyncCommands;

        let conn_id: Option<String> = self.manager.get(format!("device:{}", device_id)).await?;

        Ok(conn_id)
    }

    pub async fn create_pairing_code(
        &mut self,
        mac_device_id: &str,
        mac_device_name: &str,
        mac_public_key: &str,
        ttl: Duration,
    ) -> Result<PairingCodeEntry, PairingCodeError> {
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
                mac_device_id: mac_device_id.to_string(),
                mac_device_name: mac_device_name.to_string(),
                mac_public_key: mac_public_key.to_string(),
                issued_at,
                expires_at,
                android_device_id: None,
                android_device_name: None,
                android_public_key: None,
                challenge_json: None,
                ack_json: None,
            };

            let payload = serde_json::to_string(&entry)?;
            let mut cmd = redis::cmd("SET");
            cmd.arg(PairingCodeEntry::redis_key(&code))
                .arg(payload)
                .arg("EX")
                .arg(ttl_secs)
                .arg("NX");
            let result: Option<String> = cmd.query_async(&mut self.manager).await?;
            if result.is_some() {
                return Ok(entry);
            }
        }

        Err(PairingCodeError::AllocationFailed)
    }

    pub async fn claim_pairing_code(
        &mut self,
        code: &str,
        android_device_id: &str,
        android_device_name: &str,
        android_public_key: &str,
    ) -> Result<PairingCodeEntry, PairingCodeError> {
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        if entry.android_device_id.is_some() {
            return Err(PairingCodeError::AlreadyClaimed);
        }

        entry.android_device_id = Some(android_device_id.to_string());
        entry.android_device_name = Some(android_device_name.to_string());
        entry.android_public_key = Some(android_public_key.to_string());
        self.save_pairing_entry(&entry).await?;
        Ok(entry)
    }

    pub async fn store_pairing_challenge(
        &mut self,
        code: &str,
        android_device_id: &str,
        challenge_json: &str,
    ) -> Result<(), PairingCodeError> {
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        match entry.android_device_id.as_deref() {
            Some(id) if id == android_device_id => {
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
        mac_device_id: &str,
    ) -> Result<String, PairingCodeError> {
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        if entry.mac_device_id != mac_device_id {
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
        mac_device_id: &str,
        ack_json: &str,
    ) -> Result<(), PairingCodeError> {
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        if entry.mac_device_id != mac_device_id {
            return Err(PairingCodeError::NotFound);
        }

        entry.ack_json = Some(ack_json.to_string());
        self.save_pairing_entry(&entry).await?;
        Ok(())
    }

    pub async fn consume_pairing_ack(
        &mut self,
        code: &str,
        android_device_id: &str,
    ) -> Result<String, PairingCodeError> {
        let mut entry = self
            .load_pairing_entry(code)
            .await?
            .ok_or(PairingCodeError::NotFound)?;

        match entry.android_device_id.as_deref() {
            Some(id) if id == android_device_id => {
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
        use redis::AsyncCommands;

        let key = PairingCodeEntry::redis_key(code);
        let value: Option<String> = self.manager.get(&key).await?;
        if let Some(json) = value {
            let entry: PairingCodeEntry = serde_json::from_str(&json)?;
            if entry.expires_at <= Utc::now() {
                let _: () = self.manager.del(key).await?;
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
        use redis::AsyncCommands;

        let ttl = entry.ttl_seconds()?;
        let key = PairingCodeEntry::redis_key(&entry.code);
        let payload = serde_json::to_string(entry)?;
        self.manager.set_ex::<_, _, ()>(key, payload, ttl).await?;
        Ok(())
    }

    async fn delete_pairing_entry(&mut self, code: &str) -> Result<(), PairingCodeError> {
        use redis::AsyncCommands;

        let key = PairingCodeEntry::redis_key(code);
        let _: () = self.manager.del(key).await?;
        Ok(())
    }
}
