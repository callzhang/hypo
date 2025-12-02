use hypo_relay::services::session_manager::SessionManager;
use serde_json::json;
use tokio::time::{timeout, Duration};

#[tokio::test]
async fn multi_device_direct_and_broadcast_flow() {
    let sessions = SessionManager::new();

    let mut alice_rx = sessions.register("alice".into()).await.receiver;
    let mut bob_rx = sessions.register("bob".into()).await.receiver;
    let mut charlie_rx = sessions.register("charlie".into()).await.receiver;

    // Simulate a direct message from Alice to Bob via the handler payload contract.
    let direct_payload = json!({
        "id": "msg-1",
        "timestamp": "2025-03-01T00:00:00Z",
        "version": "1.0",
        "type": "clipboard",
        "payload": {
            "data": "clipboard-item", // Body content isn't interpreted by SessionManager
            "target": "bob"
        }
    })
    .to_string();

    sessions
        .send("bob", &direct_payload)
        .await
        .expect("target device is registered");

    let received = timeout(Duration::from_millis(50), bob_rx.recv())
        .await
        .expect("bob should receive direct message")
        .expect("channel open");
    let received_str = std::str::from_utf8(&received[4..]).expect("valid UTF-8");
    assert_eq!(received_str, direct_payload);

    assert!(
        timeout(Duration::from_millis(50), alice_rx.recv())
            .await
            .is_err(),
        "direct messages should not echo back"
    );
    assert!(
        timeout(Duration::from_millis(50), charlie_rx.recv())
            .await
            .is_err(),
        "non-target devices should not see direct payloads"
    );

    // Follow with a broadcast from Charlie so the other peers receive updates.
    let broadcast_payload = json!({
        "id": "msg-2",
        "timestamp": "2025-03-01T00:01:00Z",
        "version": "1.0",
        "type": "clipboard",
        "payload": {
            "data": "broadcast-item"
        }
    })
    .to_string();

    sessions
        .broadcast_except("charlie", &broadcast_payload)
        .await;

    let alice_view = timeout(Duration::from_millis(50), alice_rx.recv())
        .await
        .expect("alice should observe broadcast")
        .expect("channel open");
    let alice_view_str = std::str::from_utf8(&alice_view[4..]).expect("valid UTF-8");
    assert_eq!(alice_view_str, broadcast_payload);

    let bob_view = timeout(Duration::from_millis(50), bob_rx.recv())
        .await
        .expect("bob should observe broadcast")
        .expect("channel open");
    let bob_view_str = std::str::from_utf8(&bob_view[4..]).expect("valid UTF-8");
    assert_eq!(bob_view_str, broadcast_payload);
}
