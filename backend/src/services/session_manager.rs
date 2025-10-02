use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::{mpsc, RwLock};

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("device not connected")]
    DeviceNotConnected,

    #[error("session send failed: {0}")]
    SendError(String),
}

#[derive(Clone, Default)]
pub struct SessionManager {
    inner: Arc<RwLock<HashMap<String, mpsc::UnboundedSender<String>>>>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn register(&self, device_id: String) -> mpsc::UnboundedReceiver<String> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.inner.write().await.insert(device_id, tx);
        rx
    }

    pub async fn unregister(&self, device_id: &str) {
        self.inner.write().await.remove(device_id);
    }

    pub async fn broadcast_except(&self, sender_id: &str, message: &str) {
        let sessions = self.inner.read().await;
        for (id, channel) in sessions.iter() {
            if id == sender_id {
                continue;
            }
            let _ = channel.send(message.to_string());
        }
    }

    pub async fn send(&self, device_id: &str, message: &str) -> Result<(), SessionError> {
        let sessions = self.inner.read().await;
        let sender = sessions
            .get(device_id)
            .ok_or(SessionError::DeviceNotConnected)?;
        sender
            .send(message.to_string())
            .map_err(|err| SessionError::SendError(err.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::SessionManager;

    #[tokio::test]
    async fn registers_and_broadcasts_messages() {
        let manager = SessionManager::new();
        let mut rx_a = manager.register("a".to_string()).await;
        let mut rx_b = manager.register("b".to_string()).await;

        manager.broadcast_except("a", "hello").await;

        assert_eq!(rx_b.recv().await.unwrap(), "hello");
        assert!(rx_a.try_recv().is_err());

        manager.unregister("a").await;
        manager.unregister("b").await;
    }
}
