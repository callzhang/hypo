use std::time::Duration;

use actix_web::{web, HttpResponse};
use serde::{Deserialize, Serialize};

use crate::{services::redis_client::PairingCodeError, AppState};

const PAIRING_CODE_TTL: Duration = Duration::from_secs(60);

#[derive(Debug, Deserialize)]
pub struct CreatePairingCodeRequest {
    pub initiator_device_id: String,
    pub initiator_device_name: String,
    pub initiator_public_key: String,
}

#[derive(Debug, Serialize)]
pub struct CreatePairingCodeResponse {
    pub code: String,
    pub expires_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Deserialize)]
pub struct ClaimPairingCodeRequest {
    pub code: String,
    pub responder_device_id: String,
    pub responder_device_name: String,
    pub responder_public_key: String,
}

#[derive(Debug, Serialize)]
pub struct ClaimPairingCodeResponse {
    pub initiator_device_id: String,
    pub initiator_device_name: String,
    pub initiator_public_key: String,
    pub expires_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Deserialize)]
pub struct SubmitChallengeRequest {
    pub responder_device_id: String,
    pub challenge: String,
}

#[derive(Debug, Serialize)]
pub struct ChallengePayloadResponse {
    pub challenge: String,
}

#[derive(Debug, Deserialize)]
pub struct SubmitAckRequest {
    pub initiator_device_id: String,
    pub ack: String,
}

#[derive(Debug, Serialize)]
pub struct AckPayloadResponse {
    pub ack: String,
}

#[derive(Debug, Deserialize)]
pub struct CodePath {
    pub code: String,
}

#[derive(Debug, Deserialize)]
pub struct ChallengePollQuery {
    pub initiator_device_id: String,
}

#[derive(Debug, Deserialize)]
pub struct AckPollQuery {
    pub responder_device_id: String,
}

pub async fn create_pairing_code(
    data: web::Data<AppState>,
    request: web::Json<CreatePairingCodeRequest>,
) -> Result<HttpResponse, PairingCodeError> {
    let mut redis = data.redis.clone();
    let entry = redis
        .create_pairing_code(
            &request.initiator_device_id,
            &request.initiator_device_name,
            &request.initiator_public_key,
            PAIRING_CODE_TTL,
        )
        .await?;

    Ok(HttpResponse::Ok().json(CreatePairingCodeResponse {
        code: entry.code,
        expires_at: entry.expires_at,
    }))
}

pub async fn claim_pairing_code(
    data: web::Data<AppState>,
    request: web::Json<ClaimPairingCodeRequest>,
) -> Result<HttpResponse, PairingCodeError> {
    let mut redis = data.redis.clone();
    let entry = redis
        .claim_pairing_code(
            &request.code,
            &request.responder_device_id,
            &request.responder_device_name,
            &request.responder_public_key,
        )
        .await?;

    Ok(HttpResponse::Ok().json(ClaimPairingCodeResponse {
        initiator_device_id: entry.initiator_device_id,
        initiator_device_name: entry.initiator_device_name,
        initiator_public_key: entry.initiator_public_key,
        expires_at: entry.expires_at,
    }))
}

pub async fn submit_challenge(
    data: web::Data<AppState>,
    path: web::Path<CodePath>,
    request: web::Json<SubmitChallengeRequest>,
) -> Result<HttpResponse, PairingCodeError> {
    let mut redis = data.redis.clone();
    redis
        .store_pairing_challenge(&path.code, &request.responder_device_id, &request.challenge)
        .await?;
    Ok(HttpResponse::Accepted().finish())
}

pub async fn poll_challenge(
    data: web::Data<AppState>,
    path: web::Path<CodePath>,
    query: web::Query<ChallengePollQuery>,
) -> Result<HttpResponse, PairingCodeError> {
    let mut redis = data.redis.clone();
    let challenge = redis
        .consume_pairing_challenge(&path.code, &query.initiator_device_id)
        .await?;
    Ok(HttpResponse::Ok().json(ChallengePayloadResponse { challenge }))
}

pub async fn submit_ack(
    data: web::Data<AppState>,
    path: web::Path<CodePath>,
    request: web::Json<SubmitAckRequest>,
) -> Result<HttpResponse, PairingCodeError> {
    let mut redis = data.redis.clone();
    redis
        .store_pairing_ack(&path.code, &request.initiator_device_id, &request.ack)
        .await?;
    Ok(HttpResponse::Accepted().finish())
}

pub async fn poll_ack(
    data: web::Data<AppState>,
    path: web::Path<CodePath>,
    query: web::Query<AckPollQuery>,
) -> Result<HttpResponse, PairingCodeError> {
    let mut redis = data.redis.clone();
    let ack = redis
        .consume_pairing_ack(&path.code, &query.responder_device_id)
        .await?;
    Ok(HttpResponse::Ok().json(AckPayloadResponse { ack }))
}
