use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use tokio::sync::{mpsc, RwLock};

type BinaryFrame = Vec<u8>;
type SessionChannel = mpsc::UnboundedSender<BinaryFrame>;

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("device not connected")]
    DeviceNotConnected,

    #[error("session send failed: {0}")]
    SendError(String),

    #[error("invalid message format")]
    InvalidMessage,
}

#[derive(Clone, Default)]
pub struct SessionManager {
    inner: Arc<RwLock<HashMap<String, SessionEntry>>>,
    next_token: Arc<AtomicU64>,
}

#[derive(Clone)]
struct SessionEntry {
    sender: SessionChannel,
    token: u64,
}

pub struct Registration {
    pub receiver: mpsc::UnboundedReceiver<BinaryFrame>,
    pub token: u64,
}

impl SessionManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn register(&self, device_id: String) -> Registration {
        let (tx, rx) = mpsc::unbounded_channel();
        let token = self.next_token.fetch_add(1, Ordering::Relaxed);
        let mut sessions = self.inner.write().await;
        if sessions.contains_key(&device_id) {
            tracing::warn!("Device {} already registered, replacing previous session", device_id);
        }
        sessions.insert(
            device_id.clone(),
            SessionEntry {
                sender: tx,
                token,
            },
        );
        let count = sessions.len();
        tracing::info!(
            "Registered device: {} (token={}). Total sessions: {}",
            device_id,
            token,
            count
        );
        drop(sessions);
        Registration { receiver: rx, token }
    }

    pub async fn unregister(&self, device_id: &str) {
        self.inner.write().await.remove(device_id);
    }

    /// Remove a device session only if the token matches the currently registered connection.
    /// Returns true if the session was removed, false if a newer session is active.
    pub async fn unregister_with_token(&self, device_id: &str, token: u64) -> bool {
        let mut sessions = self.inner.write().await;
        let should_remove = matches!(sessions.get(device_id), Some(entry) if entry.token == token);
        if should_remove {
            sessions.remove(device_id);
        } else {
            tracing::debug!(
                "Skip unregister for {}: token {} is stale",
                device_id,
                token
            );
        }
        should_remove
    }

    pub async fn broadcast_except(&self, sender_id: &str, message: &str) {
        let binary_frame = encode_binary_frame(message);
        self.broadcast_except_binary(sender_id, binary_frame).await;
    }

    pub async fn broadcast_except_binary(&self, sender_id: &str, frame: BinaryFrame) {
        let sessions = self.inner.read().await;
        for (id, entry) in sessions.iter() {
            if id == sender_id {
                continue;
            }
            let _ = entry.sender.send(frame.clone());
        }
    }

    pub async fn send(&self, device_id: &str, message: &str) -> Result<(), SessionError> {
        let binary_frame = encode_binary_frame(message);
        self.send_binary(device_id, binary_frame).await
    }

    pub async fn send_binary(&self, device_id: &str, frame: BinaryFrame) -> Result<(), SessionError> {
        let sessions = self.inner.read().await;
        let registered_devices: Vec<String> = sessions.keys().cloned().collect();
        tracing::info!("Attempting to send to device: {}. Registered devices: {:?}", device_id, registered_devices);
        let sender = sessions
            .get(device_id)
            .ok_or_else(|| {
                tracing::warn!("Device {} not found in sessions. Available: {:?}", device_id, registered_devices);
                SessionError::DeviceNotConnected
            })?;
        sender
            .sender
            .send(frame)
            .map_err(|err| {
                tracing::error!("Failed to send to device {}: {}", device_id, err);
                SessionError::SendError(err.to_string())
            })
    }

    pub async fn get_active_count(&self) -> usize {
        self.inner.read().await.len()
    }

    pub async fn get_connected_devices(&self) -> Vec<String> {
        self.inner.read().await.keys().cloned().collect()
    }
}

/// Encode JSON string to binary frame (4-byte big-endian length + JSON payload)
fn encode_binary_frame(json_str: &str) -> Vec<u8> {
    let json_bytes = json_str.as_bytes();
    let length = json_bytes.len() as u32;
    
    let mut frame = Vec::with_capacity(4 + json_bytes.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(json_bytes);
    frame
}

#[cfg(test)]
mod tests {
    use super::{SessionError, SessionManager};
    use tokio::time::{sleep, Duration};

    #[tokio::test]
    async fn registers_and_broadcasts_messages() {
        let manager = SessionManager::new();
        let mut rx_a = manager.register("a".to_string()).await.receiver;
        let mut rx_b = manager.register("b".to_string()).await.receiver;

        manager.broadcast_except("a", "hello").await;

        // Decode binary frame
        let frame = rx_b.recv().await.unwrap();
        let json_str = std::str::from_utf8(&frame[4..]).unwrap();
        assert_eq!(json_str, "hello");
        assert!(rx_a.try_recv().is_err());

        manager.unregister("a").await;
        manager.unregister("b").await;
    }

    #[tokio::test]
    async fn send_routes_direct_messages_and_errors_for_unknown_device() {
        let manager = SessionManager::new();
        let mut rx = manager.register("device-a".to_string()).await.receiver;

        manager.send("device-a", "direct").await.expect("send succeeds");
        // Decode binary frame
        let frame = rx.recv().await.unwrap();
        let json_str = std::str::from_utf8(&frame[4..]).unwrap();
        assert_eq!(json_str, "direct");

        let err = manager.send("missing", "payload").await.unwrap_err();
        assert!(matches!(err, SessionError::DeviceNotConnected));
    }

    #[tokio::test]
    async fn unregister_closes_channel() {
        let manager = SessionManager::new();
        let mut rx = manager.register("temporary".to_string()).await.receiver;
        manager.unregister("temporary").await;

        // Give the background drop a brief moment to propagate the close signal.
        sleep(Duration::from_millis(10)).await;

        assert!(rx.recv().await.is_none());
        let err = manager.send("temporary", "payload").await.unwrap_err();
        assert!(matches!(err, SessionError::DeviceNotConnected));
    }

    #[tokio::test]
    async fn re_registering_replaces_existing_channel() {
        let manager = SessionManager::new();
        let mut first_rx = manager.register("dup".to_string()).await.receiver;
        let mut second_rx = manager.register("dup".to_string()).await.receiver;

        // Old receiver should be closed because its sender has been replaced.
        assert!(first_rx.recv().await.is_none());

        manager.send("dup", "latest").await.unwrap();
        let frame = second_rx.recv().await.unwrap();
        let json_str = std::str::from_utf8(&frame[4..]).unwrap();
        assert_eq!(json_str, "latest");
    }

    #[tokio::test]
    async fn broadcast_scales_with_multiple_consumers() {
        let manager = SessionManager::new();
        let mut receivers = Vec::new();

        for idx in 0..8 {
            let id = format!("device-{idx}");
            receivers.push(manager.register(id).await.receiver);
        }

        manager.broadcast_except("device-3", "fanout").await;

        for (idx, mut rx) in receivers.into_iter().enumerate() {
            if idx == 3 {
                assert!(rx.try_recv().is_err());
            } else {
                let frame = rx.recv().await.unwrap();
                let json_str = std::str::from_utf8(&frame[4..]).unwrap();
                assert_eq!(json_str, "fanout");
            }
        }
    }

    #[tokio::test]
    async fn stale_session_does_not_unregister_newer_connection() {
        let manager = SessionManager::new();

        let old = manager.register("device-x".to_string()).await;
        let mut old_rx = old.receiver;

        let new = manager.register("device-x".to_string()).await;
        let mut new_rx = new.receiver;

        // Simulate the old connection shutting down and trying to unregister.
        let removed = manager
            .unregister_with_token("device-x", old.token)
            .await;
        assert!(
            !removed,
            "old session should not remove the latest registration"
        );

        manager
            .send("device-x", "hello")
            .await
            .expect("new session should still be registered");

        let frame = new_rx.recv().await.expect("message should reach new session");
        let json_str = std::str::from_utf8(&frame[4..]).unwrap();
        assert_eq!(json_str, "hello");

        // Old receiver should already be closed because its sender was replaced.
        assert!(old_rx.recv().await.is_none());
    }
}
