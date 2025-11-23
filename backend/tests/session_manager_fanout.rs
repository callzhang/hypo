use hypo_relay::services::session_manager::SessionManager;
use tokio::time::{timeout, Duration};

#[tokio::test]
async fn broadcasts_messages_to_all_other_clients() {
    let manager = SessionManager::new();
    let mut sender = manager.register("sender".to_string()).await.receiver;
    let mut receivers = Vec::new();

    for idx in 0..3 {
        receivers.push(manager.register(format!("receiver-{idx}")).await.receiver);
    }

    manager.broadcast_except("sender", "payload").await;

    for (idx, mut rx) in receivers.into_iter().enumerate() {
        let frame = timeout(Duration::from_millis(50), rx.recv())
            .await
            .expect("receive timeout")
            .expect("channel closed");
        // Decode binary frame (4-byte length + JSON payload)
        let json_str = std::str::from_utf8(&frame[4..]).unwrap();
        assert_eq!(json_str, "payload", "receiver {idx} should get broadcast");
    }

    assert!(timeout(Duration::from_millis(50), sender.recv()).await.is_err());
}

#[tokio::test]
async fn routes_direct_messages_to_specific_recipient() {
    let manager = SessionManager::new();
    let mut target = manager.register("target".to_string()).await.receiver;
    let _other = manager.register("other".to_string()).await.receiver;

    manager.send("target", "secret").await.expect("send succeeds");

    let frame = timeout(Duration::from_millis(50), target.recv())
        .await
        .expect("receive timeout")
        .expect("channel closed");
    // Decode binary frame (4-byte length + JSON payload)
    let json_str = std::str::from_utf8(&frame[4..]).unwrap();
    assert_eq!(json_str, "secret");
}
