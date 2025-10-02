pub mod crypto;
pub mod handlers;
pub mod middleware;
pub mod models;
pub mod services;
pub mod utils;

use std::time::Instant;

use services::{
    device_key_store::DeviceKeyStore,
    redis_client::RedisClient,
    session_manager::SessionManager,
};

#[derive(Clone)]
pub struct AppState {
    pub redis: RedisClient,
    pub start_time: Instant,
    pub sessions: SessionManager,
    pub device_keys: DeviceKeyStore,
}
