#!/usr/bin/env python3
"""
Simulate Android clipboard copy signal to macOS WebSocket server.

This script uses the common clipboard_sender module to send messages via LAN WebSocket.
It mimics the paired Android device (Xiaomi) with its real device ID and encryption key.

Usage:
    python3 scripts/simulate-android-copy.py [--host HOST] [--port PORT] [--text TEXT] [--encrypted]
    
Example:
    python3 scripts/simulate-android-copy.py --text "Hello from script!"
    python3 scripts/simulate-android-copy.py --host 192.168.1.100 --port 7010 --text "Encrypted" --encrypted
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
    send_via_lan,
    get_device_config,
    load_key_from_keychain,
    DEFAULT_ANDROID_DEVICE_ID,
    DEFAULT_ANDROID_DEVICE_NAME,
    DEFAULT_MACOS_DEVICE_ID,
    DEFAULT_MACOS_DEVICE_NAME
)

def main():
    parser = argparse.ArgumentParser(
        description="Simulate Android clipboard copy signal to macOS WebSocket server"
    )
    parser.add_argument(
        "--host",
        default="localhost",
        help="macOS WebSocket server host (default: localhost)"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=7010,
        help="macOS WebSocket server port (default: 7010)"
    )
    parser.add_argument(
        "--text",
        default="Test clipboard from script",
        help="Text to send in clipboard sync (default: 'Test clipboard from script')"
    )
    parser.add_argument(
        "--device-id",
        help=f"Sender device ID (default: {DEFAULT_ANDROID_DEVICE_ID} - Xiaomi)"
    )
    parser.add_argument(
        "--device-name",
        help=f"Sender device name (default: {DEFAULT_ANDROID_DEVICE_NAME})"
    )
    parser.add_argument(
        "--target-device-id",
        required=True,
        help="Target device ID (required)"
    )
    parser.add_argument(
        "--encrypted",
        action="store_true",
        help="Encrypt the message (uses key from keychain for sender device)"
    )
    parser.add_argument(
        "--key",
        help="Encryption key as hex string (64 hex chars = 32 bytes). If not provided and --encrypted, loads from keychain."
    )
    parser.add_argument(
        "--key-file",
        help="Path to file containing encryption key (hex string, 64 chars)"
    )
    parser.add_argument(
        "--encryption-device-id",
        help="Device ID to use for encryption key lookup in envelope payload (default: same as --device-id or real Android device ID). Use this when --device-id is a test ID but you want to use the real device's encryption key."
    )
    parser.add_argument(
        "--session-device-id",
        help="Device ID to use for WebSocket session headers (default: same as --device-id). Use a fake UUID here to avoid conflicts."
    )
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="Don't wait for server reply (default: wait for reply)"
    )
    
    args = parser.parse_args()
    
    # Use real device ID and key to avoid rejection
    # The device_id in the envelope must match a device ID that has a key stored
    # macOS validates by looking up the key using envelope.device_id
    sender_device_id = args.device_id or DEFAULT_ANDROID_DEVICE_ID
    sender_device_name = args.device_name or DEFAULT_ANDROID_DEVICE_NAME
    
    # Get target device ID (required)
    target_device_id = args.target_device_id
    
    # Handle encryption key - must match the TARGET device ID
    # When sending: encrypt with key for TARGET device (receiver looks up key using sender's device ID from envelope)
    # When simulating Android -> macOS: use key that Android has for macOS (target_device_id)
    # The envelope.deviceId will be Android's device ID, but encryption uses macOS's key
    key = None
    if args.encrypted:
        if args.key:
            try:
                key = bytes.fromhex(args.key)
                if len(key) != 32:
                    print(f"❌ Error: Key must be 64 hex characters (32 bytes), got {len(args.key)}")
                    sys.exit(1)
            except ValueError as e:
                print(f"❌ Error: Invalid hex key: {e}")
                sys.exit(1)
        elif args.key_file:
            try:
                with open(args.key_file, 'r') as f:
                    key_hex = f.read().strip()
                    key = bytes.fromhex(key_hex)
                    if len(key) != 32:
                        print(f"❌ Error: Key must be 64 hex characters (32 bytes), got {len(key_hex)}")
                        sys.exit(1)
            except Exception as e:
                print(f"❌ Error: Failed to read key file: {e}")
                sys.exit(1)
        else:
            # Load from keychain using SENDER's device ID (the opposite side)
            # Keys are symmetric: the key Android has for macOS = the key macOS has for Android
            # macOS stores the key under Android's device ID (the sender's device ID)
            # So when simulating Android -> macOS, look for key under Android's device ID
            # (the opposite side of the target)
            print(f"🔑 Loading encryption key from keychain for SENDER device: {sender_device_id}...")
            print(f"   (Keys are symmetric: key that {sender_device_name} has for target = key that target has for {sender_device_name})")
            print(f"   (macOS stores this key under {sender_device_id}, not under {target_device_id})")
            key = load_key_from_keychain(sender_device_id)
            if not key:
                print(f"❌ Error: No encryption key found in keychain for SENDER device: {sender_device_id}")
                print(f"   When simulating {sender_device_name} -> {target_device_id}, look for the key under")
                print(f"   the SENDER's device ID ({sender_device_id}), not the target's device ID.")
                print(f"   This is because keys are stored under the OTHER device's ID on each platform.")
                print(f"   Try: security find-generic-password -w -s com.hypo.clipboard.keys -a \"{sender_device_id}\" | xxd -p -c 32 | tr -d '\\n'")
                sys.exit(1)
            print(f"✅ Loaded encryption key from keychain for SENDER device: {sender_device_id}")
    
    print("🚀 Simulating Android clipboard copy via LAN WebSocket")
    print(f"   Server: ws://{args.host}:{args.port}")
    print(f"   Sender: {sender_device_name} ({sender_device_id})")
    if target_device_id:
        print(f"   Target: {target_device_id}")
    print(f"   Text: {args.text}")
    print(f"   Encryption: {'Yes (AES-256-GCM)' if args.encrypted else 'No (plaintext)'}")
    if args.encrypted:
        print(f"   ⚠️  Using real device ID and key - device_id in envelope must match stored key")
    print()
    
    # Create text payload
    payload = create_text_payload(args.text)
    
    # Determine device IDs:
    # - session_device_id: Used for WebSocket headers (use fake UUID to avoid conflicts)
    # - envelope_device_id: Used in envelope payload (use real device ID for key lookup)
    session_device_id = args.session_device_id or sender_device_id
    envelope_device_id = args.encryption_device_id or sender_device_id
    
    # Use fake UUID for WebSocket headers, real device ID in envelope payload
    # macOS validates by: key = keyProvider.key(for: envelope.deviceId), then decrypts with that key
    success = send_via_lan(
        payload=payload,
        sender_device_id=session_device_id,  # Fake UUID for WebSocket headers
        sender_device_name=sender_device_name,
        target_device_id=target_device_id,
        encrypted=args.encrypted,
        key=key,
        host=args.host,
        port=args.port,
        wait_for_reply=not args.no_wait,
        envelope_sender_device_id=envelope_device_id  # Real device ID in envelope (for key lookup)
    )
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
