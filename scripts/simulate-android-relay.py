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
from datetime import datetime
import sys

try:
    import websocket
    from websocket import create_connection, WebSocketException
except ImportError:
    print("❌ Error: websocket-client library not installed")
    print("   Install it with: pip3 install websocket-client")
    sys.exit(1)

# Cloud relay URL
RELAY_URL = "wss://hypo.fly.dev/ws"

def create_sync_envelope(text: str, device_id: str = None, device_name: str = None, target: str = None):
    """Create a SyncEnvelope in the same format as Android."""
    if device_id is None:
        device_id = f"android-{uuid.uuid4()}"
    if device_name is None:
        device_name = "Test Android Device"
    
    # Create plaintext payload (for testing, we'll use plaintext mode)
    plaintext = json.dumps({
        "content_type": "text",
        "data_base64": base64.b64encode(text.encode('utf-8')).decode('utf-8'),
        "metadata": {}
    }).encode('utf-8')
    
    # For testing, use plaintext mode (empty nonce/tag)
    ciphertext_base64 = base64.b64encode(plaintext).decode('utf-8')
    
    envelope = {
        "id": str(uuid.uuid4()),
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "version": "1.0",
        "type": "clipboard",
        "payload": {
            "content_type": "text",
            "ciphertext": ciphertext_base64,
            "device_id": device_id,
            "device_name": device_name,
            "target": target,
            "encryption": {
                "algorithm": "AES-256-GCM",
                "nonce": "",  # Plaintext mode
                "tag": ""     # Plaintext mode
            }
        }
    }
    
    return envelope

def send_via_relay(text: str, device_id: str = None, device_name: str = None, target: str = None):
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
        envelope = create_sync_envelope(text, device_id, device_name, target)
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
        
        # Wait for reply with timeout
        print(f"\n📥 Waiting for reply from relay (10s timeout)...")
        try:
            ws.settimeout(10)  # 10 second timeout
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
            print(f"⚠️ No reply received: {e}")
        
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
    
    args = parser.parse_args()
    
    if not args.target:
        print("⚠️  Warning: No target device ID specified")
        print("   The relay routes messages based on the 'target' field in the payload")
        print("   Without a target, the message will be broadcast to all connected devices")
        print("   Use --target <macos-device-id> to send to a specific device")
        print()
    
    print("🚀 Simulating Android clipboard copy via cloud relay")
    print(f"   Relay: {RELAY_URL}")
    print(f"   Text: {args.text}")
    print(f"   Target: {args.target or '(broadcast)'}")
    print()
    
    success = send_via_relay(
        text=args.text,
        device_id=args.device_id,
        device_name=args.device_name,
        target=args.target
    )
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()

