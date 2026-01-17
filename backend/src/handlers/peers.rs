use std::collections::HashSet;

use actix_web::{web, HttpResponse};
use serde::de::{self, Deserializer, SeqAccess, Visitor};
use serde::Deserialize;
use std::fmt;

use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct PeersQuery {
    #[serde(default, deserialize_with = "deserialize_device_id")]
    device_id: Vec<String>,
}

fn deserialize_device_id<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    struct DeviceIdVisitor;

    impl<'de> Visitor<'de> for DeviceIdVisitor {
        type Value = Vec<String>;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("a string or a list of strings")
        }

        fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(value
                .split(',')
                .map(str::trim)
                .filter(|id| !id.is_empty())
                .map(str::to_string)
                .collect())
        }

        fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            self.visit_str(&value)
        }

        fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
        where
            A: SeqAccess<'de>,
        {
            let mut values = Vec::new();
            while let Some(item) = seq.next_element::<String>()? {
                values.push(item);
            }
            Ok(values)
        }
    }

    deserializer.deserialize_any(DeviceIdVisitor)
}

pub async fn connected_peers_handler(
    data: web::Data<AppState>,
    query: web::Query<PeersQuery>,
) -> HttpResponse {
    let requested: HashSet<String> = query
        .device_id
        .iter()
        .flat_map(|id| id.split(','))
        .map(|id| id.trim())
        .filter(|id| !id.is_empty())
        .map(|id| id.to_lowercase())
        .collect();

    if requested.is_empty() {
        return HttpResponse::BadRequest().json(serde_json::json!({
            "error": "device_id query parameter is required"
        }));
    }

    let mut connected_devices = data.sessions.get_connected_devices_info().await;
    connected_devices.retain(|info| requested.contains(&info.device_id));

    HttpResponse::Ok().json(serde_json::json!({
        "connected_devices": connected_devices
    }))
}
