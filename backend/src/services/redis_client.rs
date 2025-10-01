use anyhow::Result;
use redis::{aio::ConnectionManager, Client};

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
}
