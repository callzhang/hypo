use hypo_relay::services::metrics::{get_metrics, initialize_metrics, Metrics};

#[tokio::test]
async fn test_metrics_initialization() {
    initialize_metrics().await.expect("Metrics should initialize");
    let metrics = get_metrics().await;
    assert!(metrics.is_some());
}

#[tokio::test]
async fn test_metrics_counters() {
    initialize_metrics().await.expect("Metrics should initialize");
    let metrics = get_metrics().await.unwrap();
    
    // Test websocket connections
    assert_eq!(metrics.websocket_connections.load(std::sync::atomic::Ordering::Relaxed), 0);
    metrics.increment_websocket_connections();
    assert_eq!(metrics.websocket_connections.load(std::sync::atomic::Ordering::Relaxed), 1);
    metrics.decrement_websocket_connections();
    assert_eq!(metrics.websocket_connections.load(std::sync::atomic::Ordering::Relaxed), 0);
    
    // Test messages processed
    assert_eq!(metrics.messages_processed.load(std::sync::atomic::Ordering::Relaxed), 0);
    metrics.increment_messages();
    metrics.increment_messages();
    assert_eq!(metrics.messages_processed.load(std::sync::atomic::Ordering::Relaxed), 2);
    
    // Test redis operations
    assert_eq!(metrics.redis_operations.load(std::sync::atomic::Ordering::Relaxed), 0);
    metrics.increment_redis_ops();
    assert_eq!(metrics.redis_operations.load(std::sync::atomic::Ordering::Relaxed), 1);
    
    // Test error count
    assert_eq!(metrics.error_count.load(std::sync::atomic::Ordering::Relaxed), 0);
    metrics.increment_errors();
    metrics.increment_errors();
    assert_eq!(metrics.error_count.load(std::sync::atomic::Ordering::Relaxed), 2);
}

#[tokio::test]
async fn test_metrics_request_durations() {
    let metrics = Metrics::new();
    
    // Record some durations
    metrics.record_request_duration(0.1).await; // 100ms
    metrics.record_request_duration(0.2).await; // 200ms
    metrics.record_request_duration(0.3).await; // 300ms
    
    let durations = metrics.request_durations.read().await;
    assert_eq!(durations.len(), 3);
    assert!((durations[0] - 0.1).abs() < 0.001);
    assert!((durations[1] - 0.2).abs() < 0.001);
    assert!((durations[2] - 0.3).abs() < 0.001);
}

#[tokio::test]
async fn test_metrics_request_durations_limits_to_1000() {
    let metrics = Metrics::new();
    
    // Record more than 1000 durations
    for i in 0..1500 {
        metrics.record_request_duration(i as f64 * 0.001).await;
    }
    
    let durations = metrics.request_durations.read().await;
    // Should keep only the last 1000 (after draining first 500 when exceeding 1000)
    assert!(durations.len() <= 1000);
    // Should have the most recent values
    assert!((durations.last().unwrap() - 1.499).abs() < 0.001);
}

#[tokio::test]
async fn test_metrics_get_stats() {
    let metrics = Metrics::new();
    
    metrics.increment_websocket_connections();
    metrics.increment_messages();
    metrics.increment_redis_ops();
    metrics.increment_errors();
    metrics.record_request_duration(0.1).await;
    metrics.record_request_duration(0.2).await;
    
    let stats = metrics.get_stats().await;
    
    assert_eq!(stats.get("websocket_connections"), Some(&"1".to_string()));
    assert_eq!(stats.get("messages_processed"), Some(&"1".to_string()));
    assert_eq!(stats.get("redis_operations"), Some(&"1".to_string()));
    assert_eq!(stats.get("error_count"), Some(&"1".to_string()));
    assert!(stats.contains_key("avg_request_duration_ms"));
    
    let avg_duration = stats.get("avg_request_duration_ms").unwrap();
    let avg: f64 = avg_duration.parse().unwrap();
    // Average of 0.1 and 0.2 is 0.15, which is 150ms
    assert!((avg - 150.0).abs() < 1.0);
}

#[tokio::test]
async fn test_metrics_empty_request_durations() {
    let metrics = Metrics::new();
    let stats = metrics.get_stats().await;
    
    // Should not have avg_request_duration_ms if no durations recorded
    assert!(!stats.contains_key("avg_request_duration_ms"));
}

