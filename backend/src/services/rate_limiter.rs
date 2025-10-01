use std::sync::{Arc, Mutex};
use std::time::Instant;

#[derive(Clone)]
pub struct RateLimiter {
    tokens: Arc<Mutex<f64>>,
    max_tokens: f64,
    refill_rate: f64, // tokens per second
    last_refill: Arc<Mutex<Instant>>,
}

impl RateLimiter {
    pub fn new(max_tokens: f64, refill_rate: f64) -> Self {
        Self {
            tokens: Arc::new(Mutex::new(max_tokens)),
            max_tokens,
            refill_rate,
            last_refill: Arc::new(Mutex::new(Instant::now())),
        }
    }

    pub fn allow(&self) -> bool {
        let mut tokens = self.tokens.lock().unwrap();
        let mut last_refill = self.last_refill.lock().unwrap();
        
        // Refill tokens based on elapsed time
        let now = Instant::now();
        let elapsed = now.duration_since(*last_refill).as_secs_f64();
        *tokens = (*tokens + elapsed * self.refill_rate).min(self.max_tokens);
        *last_refill = now;
        
        // Check if we have tokens
        if *tokens >= 1.0 {
            *tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn test_rate_limiter_allows_within_limit() {
        let limiter = RateLimiter::new(3.0, 1.0);
        
        assert!(limiter.allow());
        assert!(limiter.allow());
        assert!(limiter.allow());
    }

    #[test]
    fn test_rate_limiter_blocks_over_limit() {
        let limiter = RateLimiter::new(2.0, 1.0);
        
        assert!(limiter.allow());
        assert!(limiter.allow());
        assert!(!limiter.allow()); // Should be blocked
    }

    #[test]
    fn test_rate_limiter_refills() {
        let limiter = RateLimiter::new(1.0, 10.0); // 10 tokens per second
        
        assert!(limiter.allow());
        assert!(!limiter.allow()); // Blocked
        
        thread::sleep(Duration::from_millis(150)); // Wait 150ms for refill
        
        assert!(limiter.allow()); // Should be allowed after refill
    }
}

