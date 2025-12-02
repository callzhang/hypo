#!/usr/bin/env python3
"""
Simulate Android clipboard sync via cloud relay.

This script is a wrapper around clipboard_sender.send_via_cloud_relay() for command-line use.
It mimics the paired Android device sending clipboard data via the cloud relay.

Usage:
    python3 scripts/simulate-android-relay.py [--text TEXT] [--target-device-id ID] [--encrypted] [--key KEY]
    
Example:
    python3 scripts/simulate-android-relay.py --text "Hello from relay!"
    python3 scripts/simulate-android-relay.py --text "Encrypted" --encrypted --key <hex_key>
"""

import argparse
import sys
import os

# Add scripts directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from clipboard_sender import (
    create_text_payload,
    create_image_payload,
    create_link_payload,
    send_via_cloud_relay,
    get_device_config,
    DEFAULT_ANDROID_DEVICE_ID,
    DEFAULT_ANDROID_DEVICE_NAME
)

def main():
    parser = argparse.ArgumentParser(
        description="Simulate Android clipboard sync via cloud relay"
    )
    parser.add_argument(
        "--text",
        default="Test clipboard from script",
        help="Text to send in clipboard sync (default: 'Test clipboard from script')"
    )
    parser.add_argument(
        "--device-id",
        default=None,
        help="Device ID to use (default: auto-generated or from clipboard_sender defaults)"
    )
    parser.add_argument(
        "--device-name",
        default="[SIM] Test Device",
        help="Device name to use (default: '[SIM] Test Device')"
    )
    parser.add_argument(
        "--target-device-id",
        default=None,
        help="Target device ID for routing (optional)"
    )
    parser.add_argument(
        "--session-device-id",
        default=None,
        help="Device ID for WebSocket session (default: same as --device-id)"
    )
    parser.add_argument(
        "--encrypted",
        action="store_true",
        help="Encrypt the message (requires --key or --encryption-device-id)"
    )
    parser.add_argument(
        "--key",
        default=None,
        help="Encryption key as hex string (32 bytes = 64 hex chars)"
    )
    parser.add_argument(
        "--encryption-device-id",
        default=None,
        help="Device ID to use for encryption key lookup (default: --device-id)"
    )
    parser.add_argument(
        "--relay-url",
        default="wss://hypo.fly.dev/ws",
        help="Cloud relay WebSocket URL (default: wss://hypo.fly.dev/ws)"
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress output (for batch operations)"
    )
    
    args = parser.parse_args()
    
    # Determine device IDs
    device_id = args.device_id or DEFAULT_ANDROID_DEVICE_ID
    device_name = args.device_name or DEFAULT_ANDROID_DEVICE_NAME
    session_device_id = args.session_device_id or device_id
    encryption_device_id = args.encryption_device_id or device_id
    
    # Create text payload
    payload = create_text_payload(args.text)
    
    # Handle encryption
    key_bytes = None
    if args.encrypted:
        if args.key:
            try:
                key_bytes = bytes.fromhex(args.key)
                if len(key_bytes) != 32:
                    print(f"❌ Error: Key must be 32 bytes (64 hex chars), got {len(key_bytes)} bytes")
                    sys.exit(1)
            except ValueError as e:
                print(f"❌ Error: Invalid hex key: {e}")
                sys.exit(1)
        else:
            # Try to load from keychain (macOS only)
            from clipboard_sender import load_key_from_keychain
            key_bytes = load_key_from_keychain(encryption_device_id)
            if not key_bytes:
                print(f"❌ Error: Encryption requested but no key provided and key not found in keychain for device: {encryption_device_id}")
                print("   Use --key <hex_key> or ensure device is paired")
                sys.exit(1)
    
    # Send via cloud relay
    success = send_via_cloud_relay(
        payload=payload,
        sender_device_id=encryption_device_id,  # Use encryption_device_id for key lookup
        sender_device_name=device_name,
        target_device_id=args.target_device_id,
        encrypted=args.encrypted,
        key=key_bytes,
        relay_url=args.relay_url,
        session_device_id=session_device_id,  # Use session_device_id for WebSocket headers
        quiet=args.quiet
    )
    
    if success:
        if not args.quiet:
            print("✅ Clipboard sync message sent successfully")
        sys.exit(0)
    else:
        if not args.quiet:
            print("❌ Failed to send clipboard sync message")
        sys.exit(1)

if __name__ == "__main__":
    main()

