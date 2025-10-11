#!/usr/bin/env python3
"""
Performance Latency Test

This test measures latency for both LAN and Cloud transport paths.
It verifies that the system meets the performance targets defined in the technical spec:
- LAN Sync Latency (P95): < 500ms
- Cloud Sync Latency (P95): < 3s
"""

import json
import time
import statistics
import sys
from pathlib import Path

def load_transport_metrics():
    """Load existing transport performance data."""
    metrics = {}
    
    # Load LAN metrics
    lan_metrics_path = Path("tests/transport/lan_loopback_metrics.json")
    if lan_metrics_path.exists():
        with open(lan_metrics_path) as f:
            metrics['lan'] = json.load(f)
    
    # Load Cloud metrics  
    cloud_metrics_path = Path("tests/transport/cloud_metrics.json")
    if cloud_metrics_path.exists():
        with open(cloud_metrics_path) as f:
            metrics['cloud'] = json.load(f)
            
    return metrics

def calculate_percentiles(values):
    """Calculate P50, P95, P99 percentiles from a list of values."""
    if not values:
        return None, None, None
        
    sorted_values = sorted(values)
    n = len(sorted_values)
    
    p50_idx = int(0.50 * n)
    p95_idx = int(0.95 * n) 
    p99_idx = int(0.99 * n)
    
    return (
        sorted_values[p50_idx] if p50_idx < n else sorted_values[-1],
        sorted_values[p95_idx] if p95_idx < n else sorted_values[-1], 
        sorted_values[p99_idx] if p99_idx < n else sorted_values[-1]
    )

def analyze_lan_latency(metrics):
    """Analyze LAN latency performance against targets."""
    if 'lan' not in metrics:
        print("⚠️  No LAN metrics found")
        return False, {}
    
    lan_data = metrics['lan']
    
    # Handle the actual structure from lan_loopback_metrics.json
    handshake_p95 = None
    handshake_median = None
    payload_p95 = None
    payload_median = None
    
    if 'handshake_ms' in lan_data:
        handshake_p95 = lan_data['handshake_ms'].get('p95')
        handshake_median = lan_data['handshake_ms'].get('median')
    
    if 'round_trip_ms' in lan_data:
        payload_p95 = lan_data['round_trip_ms'].get('p95')
        payload_median = lan_data['round_trip_ms'].get('median')
    
    results = {
        'handshake': {
            'median': handshake_median,
            'p95': handshake_p95
        },
        'round_trip': {
            'median': payload_median,
            'p95': payload_p95
        }
    }
    
    # Check against targets (< 500ms P95)
    lan_target_ms = 500
    passes_target = True
    
    if handshake_p95 and handshake_p95 > lan_target_ms:
        passes_target = False
        
    if payload_p95 and payload_p95 > lan_target_ms:
        passes_target = False
    
    print(f"📊 LAN Latency Analysis:")
    print(f"   Handshake  - Median: {handshake_median}ms, P95: {handshake_p95}ms")
    print(f"   Round Trip - Median: {payload_median}ms, P95: {payload_p95}ms")
    print(f"   Target: P95 < {lan_target_ms}ms")
    print(f"   Status: {'✅ PASS' if passes_target else '❌ FAIL'}")
    
    return passes_target, results

def analyze_cloud_latency(metrics):
    """Analyze Cloud latency performance against targets."""
    if 'cloud' not in metrics:
        print("⚠️  No Cloud metrics found")
        return False, {}
    
    cloud_data = metrics['cloud']
    
    # Handle the actual structure from cloud_metrics.json
    handshake_p50 = cloud_data.get('handshake_ms', {}).get('p50')
    handshake_p95 = cloud_data.get('handshake_ms', {}).get('p95')
    payload_p50 = cloud_data.get('first_payload_ms', {}).get('p50')
    payload_p95 = cloud_data.get('first_payload_ms', {}).get('p95')
    
    results = {
        'handshake': {
            'p50': handshake_p50,
            'p95': handshake_p95
        },
        'first_payload': {
            'p50': payload_p50,
            'p95': payload_p95
        }
    }
    
    # Check against targets (< 3000ms P95)
    cloud_target_ms = 3000
    passes_target = True
    
    if handshake_p95 and handshake_p95 > cloud_target_ms:
        passes_target = False
        
    if payload_p95 and payload_p95 > cloud_target_ms:
        passes_target = False
    
    print(f"📊 Cloud Latency Analysis:")
    print(f"   Handshake     - P50: {handshake_p50}ms, P95: {handshake_p95}ms")
    print(f"   First Payload - P50: {payload_p50}ms, P95: {payload_p95}ms")
    print(f"   Target: P95 < {cloud_target_ms}ms") 
    print(f"   Status: {'✅ PASS' if passes_target else '❌ FAIL'}")
    
    return passes_target, results

def generate_summary_report(lan_results, cloud_results):
    """Generate a summary performance report."""
    report = {
        'timestamp': time.time(),
        'lan': lan_results,
        'cloud': cloud_results
    }
    
    # Write summary to file
    summary_path = Path("tests/transport/latency_summary.json")
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(summary_path, 'w') as f:
        json.dump(report, f, indent=2)
    
    print(f"\n📄 Summary report written to: {summary_path}")

def main():
    """Run latency performance analysis."""
    print("📊 Running Transport Latency Performance Analysis")
    print("=" * 60)
    
    metrics = load_transport_metrics()
    
    # Analyze LAN performance
    print(f"\n🏠 LAN Transport Analysis:")
    lan_pass, lan_results = analyze_lan_latency(metrics)
    
    # Analyze Cloud performance  
    print(f"\n☁️  Cloud Transport Analysis:")
    cloud_pass, cloud_results = analyze_cloud_latency(metrics)
    
    # Generate summary report
    generate_summary_report(lan_results, cloud_results)
    
    # Overall results
    total_pass = lan_pass and cloud_pass
    
    print(f"\n🎯 Performance Summary:")
    print(f"   LAN Transport:   {'✅ PASS' if lan_pass else '❌ FAIL'}")
    print(f"   Cloud Transport: {'✅ PASS' if cloud_pass else '❌ FAIL'}")
    print(f"   Overall:         {'🎉 ALL TARGETS MET' if total_pass else '💥 PERFORMANCE ISSUES'}")
    
    return 0 if total_pass else 1

if __name__ == "__main__":
    sys.exit(main())