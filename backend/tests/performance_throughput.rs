use hypo_relay::services::session_manager::SessionManager;
use tokio::time::{timeout, Duration, Instant};

#[tokio::test]
async fn broadcast_throughput_for_hundred_messages() {
    let sessions = SessionManager::new();
    let mut sender_rx = sessions.register("sender".into()).await;
    let mut receivers = Vec::new();

    for idx in 0..4 {
        receivers.push(sessions.register(format!("receiver-{idx}")).await);
    }

    let start = Instant::now();

    for batch in 0..100 {
        let payload = format!("message-{batch}");
        sessions.broadcast_except("sender", &payload).await;

        for rx in receivers.iter_mut() {
            let received = timeout(Duration::from_millis(50), rx.recv())
                .await
                .expect("receiver should get broadcast")
                .expect("channel open");
            assert_eq!(received, payload);
        }
    }

    let elapsed = start.elapsed();
    assert!(elapsed <= Duration::from_millis(500), "broadcast took {:?}", elapsed);

    // Sender should never receive its own broadcasts
    assert!(sender_rx.try_recv().is_err());
}
