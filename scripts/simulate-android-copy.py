#!/usr/bin/env python3
"""
Simulate Android clipboard copy signal to macOS WebSocket server.

This script connects to the macOS WebSocket server and sends a clipboard
sync message in the same format as Android would send it.

Usage:
    python3 scripts/simulate-android-copy.py [--host HOST] [--port PORT] [--text TEXT]
    
Example:
    python3 scripts/simulate-android-copy.py --text "Hello from script!"
    python3 scripts/simulate-android-copy.py --host 192.168.1.100 --port 7010
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
    
    # Base64 encode
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
    
    # macOS expects id as UUID string, timestamp as ISO8601 date string
    envelope = {
        "id": str(uuid.uuid4()),  # UUID string format
        "timestamp": datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),  # ISO8601 with Z
        "version": "1.0",
        "type": "clipboard",  # lowercase, matches MessageType.clipboard
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

def encode_frame(envelope: dict) -> bytes:
    """Encode envelope using TransportFrameCodec format (4-byte length + JSON)."""
    # Convert to JSON with snake_case keys (Android uses snake_case)
    json_str = json.dumps(envelope, separators=(',', ':'))
    json_bytes = json_str.encode('utf-8')
    
    # Prepend 4-byte big-endian length
    length_bytes = struct.pack('>I', len(json_bytes))
    
    return length_bytes + json_bytes

def decode_frame(data: bytes) -> dict:
    """Decode TransportFrameCodec frame (4-byte length + JSON) or direct JSON."""
    # Try to decode as frame-encoded first (4-byte length prefix)
    if len(data) >= 4:
        # Check if it starts with a reasonable length (not a huge number)
        length = struct.unpack('>I', data[:4])[0]
        
        # If length is reasonable (less than 10MB) and matches frame size, it's frame-encoded
        if length < 10 * 1024 * 1024 and len(data) >= 4 + length:
            # Extract JSON payload
            json_bytes = data[4:4+length]
            json_str = json_bytes.decode('utf-8')
            envelope = json.loads(json_str)
            return envelope
    
    # Otherwise, try to decode as direct JSON (macOS might send JSON directly)
    try:
        json_str = data.decode('utf-8')
        envelope = json.loads(json_str)
        return envelope
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError(f"Could not decode as frame or JSON. First 100 bytes: {data[:100]}")

def decode_clipboard_payload(envelope: dict) -> str:
    """Decode clipboard payload from envelope (plaintext mode)."""
    payload = envelope.get('payload', {})
    encryption = payload.get('encryption', {})
    ciphertext_b64 = payload.get('ciphertext', '')
    
    # Check if plaintext mode (empty nonce/tag)
    is_plaintext = not encryption.get('nonce') or not encryption.get('tag')
    
    if is_plaintext:
        # Decode base64 ciphertext (which is actually plaintext JSON)
        ciphertext = base64.b64decode(ciphertext_b64)
        payload_json = json.loads(ciphertext.decode('utf-8'))
        
        # Extract data_base64 and decode
        data_b64 = payload_json.get('data_base64', '')
        data = base64.b64decode(data_b64)
        return data.decode('utf-8')
    else:
        # Encrypted mode - would need decryption key
        return f"[ENCRYPTED - nonce: {encryption.get('nonce', '')[:20]}...]"

def send_clipboard_sync(host: str = "localhost", port: int = 7010, text: str = "Test clipboard from script", wait_for_reply: bool = True, encrypted: bool = False, key: bytes = None, device_id: str = None, device_name: str = None, target: str = None):
    """Connect to macOS WebSocket server and send clipboard sync message."""
    url = f"ws://{host}:{port}"
    
    print(f"🔌 Connecting to {url}...")
    
    try:
        # Create WebSocket connection with timeout
        ws = create_connection(url, timeout=10)
        print(f"✅ Connected to WebSocket server")
        
        # Set socket timeout for receive operations
        ws.settimeout(10)  # 10 second timeout for all operations
        
        # Create sync envelope
        envelope = create_sync_envelope(text, device_id=device_id, device_name=device_name, target=target, encrypted=encrypted, key=key)
        print(f"📤 Created sync envelope: id={envelope['id'][:8]}...")
        if encrypted:
            print(f"   🔒 Encrypted: nonce={envelope['payload']['encryption']['nonce'][:20]}..., tag={envelope['payload']['encryption']['tag'][:20]}...")
        else:
            print(f"   📝 Plaintext mode")
        
        # Encode frame (4-byte length + JSON)
        frame_payload = encode_frame(envelope)
        print(f"📤 Frame payload: {len(frame_payload)} bytes")
        
        # Send as WebSocket binary frame (websocket-client auto-detects binary from bytes)
        ws.send(frame_payload)
        print(f"✅ Sent clipboard sync message: {len(frame_payload)} bytes")
        print(f"   Text: {text}")
        print(f"   Device: {envelope['payload']['device_name']} ({envelope['payload']['device_id'][:20]}...)")
        
        if wait_for_reply:
            print(f"\n📥 Waiting for server reply (keep connection open for 10 seconds)...")
            print(f"   (Copy something on macOS to trigger a send)")
            try:
                # Wait for reply (with longer timeout to catch macOS clipboard events)
                ws.settimeout(10)  # 10 second timeout
                reply = ws.recv()
                
                if isinstance(reply, bytes):
                    print(f"📥 Received binary reply: {len(reply)} bytes")
                    try:
                        # Decode frame (macOS sends JSON directly, not frame-encoded)
                        reply_envelope = decode_frame(reply)
                        print(f"✅ Decoded envelope:")
                        print(f"   Type: {reply_envelope.get('type')}")
                        print(f"   ID: {reply_envelope.get('id', '')[:8]}...")
                        print(f"   Version: {reply_envelope.get('version')}")
                        
                        payload = reply_envelope.get('payload', {})
                        encryption = payload.get('encryption', {})
                        device_name = payload.get('device_name', 'Unknown')
                        device_id = payload.get('device_id', 'Unknown')
                        content_type = payload.get('content_type', 'Unknown')
                        
                        print(f"   From: {device_name} ({device_id[:20]}...)")
                        print(f"   Content type: {content_type}")
                        
                        # Check if encrypted
                        nonce = encryption.get('nonce', '')
                        tag = encryption.get('tag', '')
                        is_encrypted = bool(nonce and tag)
                        
                        if is_encrypted:
                            print(f"   🔒 Encrypted (nonce: {nonce[:20]}..., tag: {tag[:20]}...)")
                            print(f"   ⚠️  Cannot decrypt without pairing key")
                        else:
                            # Decode clipboard payload (plaintext)
                            clipboard_text = decode_clipboard_payload(reply_envelope)
                            print(f"   📋 Clipboard content: {clipboard_text}")
                    except Exception as e:
                        print(f"⚠️ Failed to decode reply: {e}")
                        import traceback
                        traceback.print_exc()
                        print(f"   Raw data (first 200 bytes): {reply[:200]}")
                else:
                    print(f"📥 Received text reply: {reply}")
            except Exception as e:
                print(f"⚠️ No reply received within timeout: {e}")
                print(f"   (This is normal if macOS hasn't copied anything)")
        else:
            # Wait a bit before closing
            time.sleep(0.5)
        
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
        help="Device ID to use (default: auto-generated android-UUID)"
    )
    parser.add_argument(
        "--device-name",
        default="Test Android Device",
        help="Device name to use (default: 'Test Android Device')"
    )
    parser.add_argument(
        "--target",
        help="Target device ID (optional)"
    )
    parser.add_argument(
        "--target-platform",
        choices=["macos", "android"],
        help="Target platform (macos or android). If specified, --target-device-id is required unless using default device IDs."
    )
    parser.add_argument(
        "--target-device-id",
        help="Target device ID for the specified platform (required if --target-platform is specified and you want a custom device ID)"
    )
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="Don't wait for server reply (default: wait for reply)"
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
    
    print("🚀 Simulating Android clipboard copy signal")
    print(f"   Host: {args.host}:{args.port}")
    print(f"   Text: {args.text}")
    print(f"   Encrypted: {args.encrypted}")
    if args.target_platform:
        print(f"   Target Platform: {args.target_platform}")
    if target_device_id:
        print(f"   Target Device ID: {target_device_id}")
    print()
    
    success = send_clipboard_sync(
        host=args.host,
        port=args.port,
        text=args.text,
        wait_for_reply=not args.no_wait,
        encrypted=args.encrypted,
        key=key,
        device_id=args.device_id,
        device_name=args.device_name,
        target=target_device_id
    )
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()

