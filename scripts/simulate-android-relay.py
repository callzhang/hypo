#!/usr/bin/env python3
"""
Simulate Android clipboard copy signal to macOS via cloud relay server.

This script connects to the cloud relay WebSocket server and sends a clipboard
sync message in the format expected by the relay (JSON text, not frame-encoded).

Usage:
    python3 scripts/simulate-android-relay.py [--text TEXT] [--target TARGET_DEVICE_ID]
    
Example:
    python3 scripts/simulate-android-relay.py --text "Hello via relay!" --target macos-007E4A95-0E1A-4B10-91FA-87942EFAA68E
"""

import argparse
import base64
import json
import struct
import time
import uuid
import os
from datetime import datetime, timezone
import sys

try:
    import websocket
    from websocket import create_connection, WebSocketException
except ImportError:
    print("❌ Error: websocket-client library not installed")
    print("   Install it with: pip3 install websocket-client")
    sys.exit(1)

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.backends import default_backend
    ENCRYPTION_AVAILABLE = True
except ImportError:
    ENCRYPTION_AVAILABLE = False
    print("⚠️  Warning: cryptography library not available - encryption disabled")
    print("   Install it with: pip3 install cryptography")

# Cloud relay URL
RELAY_URL = "wss://hypo.fly.dev/ws"

def encrypt_payload(plaintext: bytes, key: bytes, device_id: str) -> tuple[str, str, str]:
    """Encrypt plaintext using AES-256-GCM.
    
    Returns: (ciphertext_base64, nonce_base64, tag_base64)
    """
    if not ENCRYPTION_AVAILABLE:
        raise RuntimeError("Encryption not available - install cryptography library")
    
    if len(key) != 32:
        raise ValueError(f"Key must be 32 bytes, got {len(key)}")
    
    # Generate 12-byte nonce (GCM standard)
    nonce = os.urandom(12)
    
    # Create AESGCM cipher
    aesgcm = AESGCM(key)
    
    # AAD = deviceId as UTF-8 bytes
    aad = device_id.encode('utf-8')
    
    # Encrypt (returns ciphertext + tag)
    encrypted = aesgcm.encrypt(nonce, plaintext, aad)
    
    # GCM returns ciphertext + tag (16 bytes at the end)
    ciphertext = encrypted[:-16]
    tag = encrypted[-16:]
    
    # Base64 encode (Android uses Base64.withoutPadding(), but standard base64 works too)
    ciphertext_b64 = base64.b64encode(ciphertext).decode('utf-8')
    nonce_b64 = base64.b64encode(nonce).decode('utf-8')
    tag_b64 = base64.b64encode(tag).decode('utf-8')
    
    return ciphertext_b64, nonce_b64, tag_b64

def create_sync_envelope(text: str, device_id: str = None, device_name: str = None, target: str = None, encrypted: bool = False, key: bytes = None):
    """Create a SyncEnvelope in the same format as Android."""
    if device_id is None:
        device_id = f"android-{uuid.uuid4()}"
    if device_name is None:
        device_name = "Test Android Device"
    
    # Create plaintext payload
    plaintext = json.dumps({
        "content_type": "text",
        "data_base64": base64.b64encode(text.encode('utf-8')).decode('utf-8'),
        "metadata": {}
    }).encode('utf-8')
    
    # Encrypt or use plaintext mode
    if encrypted and key:
        if not ENCRYPTION_AVAILABLE:
            print("⚠️  Warning: Encryption requested but cryptography library not available")
            print("   Falling back to plaintext mode")
            encrypted = False
        
        if encrypted:
            ciphertext_b64, nonce_b64, tag_b64 = encrypt_payload(plaintext, key, device_id)
        else:
            # Plaintext mode
            ciphertext_b64 = base64.b64encode(plaintext).decode('utf-8')
            nonce_b64 = ""
            tag_b64 = ""
    else:
        # Plaintext mode (default)
        ciphertext_b64 = base64.b64encode(plaintext).decode('utf-8')
        nonce_b64 = ""
        tag_b64 = ""
    
    envelope = {
        "id": str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        "version": "1.0",
        "type": "clipboard",
        "payload": {
            "content_type": "text",
            "ciphertext": ciphertext_b64,
            "device_id": device_id,
            "device_name": device_name,
            "target": target,
            "encryption": {
                "algorithm": "AES-256-GCM",
                "nonce": nonce_b64,
                "tag": tag_b64
            }
        }
    }
    
    return envelope

def send_via_relay(text: str, device_id: str = None, device_name: str = None, target: str = None, encrypted: bool = False, key: bytes = None):
    """Connect to cloud relay and send clipboard sync message."""
    print(f"🔌 Connecting to cloud relay: {RELAY_URL}...")
    
    try:
        # Create WebSocket connection
        # Note: websocket-client doesn't support custom headers in create_connection
        # The relay requires X-Device-Id and X-Device-Platform headers
        # We'll need to use a workaround or different library
        # For testing, let's try connecting and see what happens
        
        # Generate device ID if not provided
        if device_id is None:
            device_id = f"android-{uuid.uuid4()}"
        
        print(f"   Device ID: {device_id}")
        print(f"   Platform: android")
        
        # Create WebSocket connection with required headers
        headers = [
            f"X-Device-Id: {device_id}",
            "X-Device-Platform: android",
            "X-Hypo-Client: 0.2.0",
            "X-Hypo-Environment: production"
        ]
        
        # Create connection with timeout
        ws = create_connection(RELAY_URL, timeout=10, header=headers)
        print(f"✅ Connected to cloud relay")
        
        # Set socket timeout for receive operations
        ws.settimeout(10)  # 10 second timeout for all operations
        
        # Create sync envelope
        envelope = create_sync_envelope(text, device_id, device_name, target, encrypted=encrypted, key=key)
        print(f"📦 Created sync envelope: id={envelope['id'][:8]}...")
        print(f"   Target: {target or '(broadcast)'}")
        
        # Convert envelope to JSON string
        json_str = json.dumps(envelope, separators=(',', ':'))
        json_bytes = json_str.encode('utf-8')
        
        # Encode as binary frame (4-byte big-endian length + JSON payload)
        length_prefix = struct.pack('>I', len(json_bytes))
        frame = length_prefix + json_bytes
        
        print(f"📤 Sending binary frame: {len(frame)} bytes (JSON: {len(json_bytes)} bytes)")
        
        # Send as BINARY message (Android/macOS use binary frames)
        ws.send(frame, opcode=websocket.ABNF.OPCODE_BINARY)
        print(f"✅ Sent clipboard sync message via relay")
        print(f"   Text: {text}")
        print(f"   Device: {envelope['payload']['device_name']} ({envelope['payload']['device_id'][:20]}...)")
        
        # Optionally wait for reply (but don't fail if none received)
        print(f"\n📥 Waiting for reply from relay (5s timeout, optional)...")
        try:
            ws.settimeout(5)  # 5 second timeout
            reply = ws.recv()
            
            if isinstance(reply, bytes):
                print(f"📥 Received binary reply: {len(reply)} bytes")
                try:
                    # Decode binary frame (4-byte length + JSON)
                    if len(reply) >= 4:
                        length = struct.unpack('>I', reply[:4])[0]
                        if len(reply) >= 4 + length:
                            json_bytes = reply[4:4+length]
                            json_str = json_bytes.decode('utf-8')
                            reply_envelope = json.loads(json_str)
                            print(f"✅ Decoded reply envelope: type={reply_envelope.get('type')}")
                            payload = reply_envelope.get('payload', {})
                            print(f"   From: {payload.get('device_name', 'Unknown')}")
                            print(f"   Content type: {payload.get('content_type', 'Unknown')}")
                        else:
                            print(f"⚠️ Frame truncated: expected {4+length} bytes, got {len(reply)}")
                    else:
                        print(f"⚠️ Frame too short: {len(reply)} bytes")
                except Exception as e:
                    print(f"⚠️ Failed to decode reply: {e}")
                    import traceback
                    traceback.print_exc()
            elif isinstance(reply, str):
                print(f"📥 Received text reply: {len(reply)} bytes")
                try:
                    reply_envelope = json.loads(reply)
                    print(f"✅ Decoded reply envelope: type={reply_envelope.get('type')}")
                except json.JSONDecodeError as e:
                    print(f"⚠️ Failed to parse reply as JSON: {e}")
            else:
                print(f"📥 Received unknown reply type: {type(reply)}")
        except Exception as e:
            # Timeout is expected - message was sent, that's what matters
            print(f"ℹ️  No reply received (timeout expected): {type(e).__name__}")
        
        # Close connection
        ws.close()
        print(f"🔌 Connection closed")
        
        return True
        
    except WebSocketException as e:
        print(f"❌ WebSocket error: {e}")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

def main():
    parser = argparse.ArgumentParser(
        description="Simulate Android clipboard copy signal via cloud relay to macOS"
    )
    parser.add_argument(
        "--text",
        default="Test clipboard from relay script",
        help="Text to send in clipboard sync (default: 'Test clipboard from relay script')"
    )
    parser.add_argument(
        "--device-id",
        help="Device ID to use (default: auto-generated android-UUID)"
    )
    parser.add_argument(
        "--device-name",
        default="Test Android Device",
        help="Device name to use (default: 'Test Android Device')"
    )
    parser.add_argument(
        "--target",
        help="Target device ID (required for relay routing - use macOS device ID)"
    )
    parser.add_argument(
        "--target-platform",
        choices=["macos", "android"],
        help="Target platform (macos or android). If specified, --target-device-id is required unless using default device IDs."
    )
    parser.add_argument(
        "--target-device-id",
        help="Target device ID for the specified platform (required if --target-platform is specified)"
    )
    parser.add_argument(
        "--encrypted",
        action="store_true",
        help="Encrypt the message (requires --key or --key-file)"
    )
    parser.add_argument(
        "--key",
        help="Encryption key as hex string (32 bytes = 64 hex chars)"
    )
    parser.add_argument(
        "--key-file",
        help="Path to file containing encryption key (32 bytes binary or hex string)"
    )
    
    args = parser.parse_args()
    
    # Handle target platform
    target_device_id = args.target
    if args.target_platform:
        if args.target_device_id:
            target_device_id = args.target_device_id
        else:
            # Use default device IDs based on platform
            if args.target_platform == "macos":
                target_device_id = "007E4A95-0E1A-4B10-91FA-87942EFAA68E"  # Default macOS device
                print(f"ℹ️  Using default macOS device ID: {target_device_id}")
            elif args.target_platform == "android":
                target_device_id = "c7bd7e23-b5c1-4dfd-bb62-6a3b7c880760"  # Default Android device
                print(f"ℹ️  Using default Android device ID: {target_device_id}")
    
    # Handle encryption key
    key = None
    if args.encrypted:
        if args.key:
            # Key provided as hex string
            try:
                key = bytes.fromhex(args.key)
                if len(key) != 32:
                    print(f"❌ Error: Key must be 32 bytes (64 hex chars), got {len(key)} bytes")
                    sys.exit(1)
            except ValueError as e:
                print(f"❌ Error: Invalid hex key: {e}")
                sys.exit(1)
        elif args.key_file:
            # Key from file
            try:
                with open(args.key_file, 'rb') as f:
                    key_data = f.read()
                # Try hex first, then binary
                try:
                    key = bytes.fromhex(key_data.decode('utf-8').strip())
                except:
                    key = key_data
                if len(key) != 32:
                    print(f"❌ Error: Key must be 32 bytes, got {len(key)} bytes from file")
                    sys.exit(1)
            except Exception as e:
                print(f"❌ Error: Failed to read key file: {e}")
                sys.exit(1)
        else:
            print("❌ Error: --encrypted requires --key or --key-file")
            print("   Example: --encrypted --key $(security find-generic-password -w -s 'com.hypo.clipboard.keys' -a 'android-XXX' | xxd -p -c 32)")
            sys.exit(1)
    
    if not target_device_id:
        print("⚠️  Warning: No target device ID specified")
        print("   The relay routes messages based on the 'target' field in the payload")
        print("   Without a target, the message will be broadcast to all connected devices")
        print("   Use --target <device-id> or --target-platform <macos|android> to send to a specific device")
        print()
    
    print("🚀 Simulating Android clipboard copy via cloud relay")
    print(f"   Relay: {RELAY_URL}")
    print(f"   Text: {args.text}")
    print(f"   Target: {target_device_id or '(broadcast)'}")
    if args.target_platform:
        print(f"   Target Platform: {args.target_platform}")
    print()
    
    success = send_via_relay(
        text=args.text,
        device_id=args.device_id,
        device_name=args.device_name,
        target=target_device_id,
        encrypted=args.encrypted,
        key=key
    )
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()

