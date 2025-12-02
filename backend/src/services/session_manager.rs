use std::collections::HashMap;
use std::sync::Arc;
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
    inner: Arc<RwLock<HashMap<String, SessionChannel>>>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn register(&self, device_id: String) -> mpsc::UnboundedReceiver<BinaryFrame> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.inner.write().await.insert(device_id, tx);
        rx
    }

    pub async fn unregister(&self, device_id: &str) {
        self.inner.write().await.remove(device_id);
    }

    pub async fn broadcast_except(&self, sender_id: &str, message: &str) {
        let binary_frame = encode_binary_frame(message);
        self.broadcast_except_binary(sender_id, binary_frame).await;
    }

    pub async fn broadcast_except_binary(&self, sender_id: &str, frame: BinaryFrame) {
        let sessions = self.inner.read().await;
        for (id, channel) in sessions.iter() {
            if id == sender_id {
                continue;
            }
            let _ = channel.send(frame.clone());
        }
    }

    pub async fn send(&self, device_id: &str, message: &str) -> Result<(), SessionError> {
        let binary_frame = encode_binary_frame(message);
        self.send_binary(device_id, binary_frame).await
    }

    pub async fn send_binary(&self, device_id: &str, frame: BinaryFrame) -> Result<(), SessionError> {
        let sessions = self.inner.read().await;
        let sender = sessions
            .get(device_id)
            .ok_or(SessionError::DeviceNotConnected)?;
        sender
            .send(frame)
            .map_err(|err| SessionError::SendError(err.to_string()))
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
        let mut rx_a = manager.register("a".to_string()).await;
        let mut rx_b = manager.register("b".to_string()).await;

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
        let mut rx = manager.register("device-a".to_string()).await;

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
        let mut rx = manager.register("temporary".to_string()).await;
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
        let mut first_rx = manager.register("dup".to_string()).await;
        let mut second_rx = manager.register("dup".to_string()).await;

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
            receivers.push(manager.register(id).await);
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
}
