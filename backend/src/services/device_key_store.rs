use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::RwLock;

/// Simple in-memory registry that tracks symmetric encryption keys announced by
/// connected devices. The current implementation keeps the keys in-process so
/// the relay can mediate optional validation without persisting secrets.
#[derive(Clone, Default)]
pub struct DeviceKeyStore {
    inner: Arc<RwLock<HashMap<String, Vec<u8>>>>,
}

impl DeviceKeyStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn store(&self, device_id: String, key: Vec<u8>) {
        self.inner.write().await.insert(device_id, key);
    }

    pub async fn get(&self, device_id: &str) -> Option<Vec<u8>> {
        self.inner.read().await.get(device_id).cloned()
    }

    pub async fn remove(&self, device_id: &str) {
        self.inner.write().await.remove(device_id);
    }

    pub async fn is_registered(&self, device_id: &str) -> bool {
        self.inner.read().await.contains_key(device_id)
    }
}

#[cfg(test)]
mod tests {
    use super::DeviceKeyStore;

    #[tokio::test]
    async fn stores_and_fetches_keys() {
        let store = DeviceKeyStore::new();
        assert!(!store.is_registered("mac").await);

        store.store("mac".into(), vec![1, 2, 3]).await;
        assert!(store.is_registered("mac").await);

        let fetched = store.get("mac").await.expect("key present");
        assert_eq!(fetched, vec![1, 2, 3]);

        store.remove("mac").await;
        assert!(!store.is_registered("mac").await);
    }
}
