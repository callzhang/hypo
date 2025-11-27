#!/usr/bin/env python3
"""
Common clipboard message sending functions for simulation scripts.

This module provides reusable functions for sending clipboard messages
via LAN or cloud relay, with support for text, images, and other content types.
"""

import base64
import json
import struct
import uuid
import os
from datetime import datetime, timezone
from typing import Optional, Tuple

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    ENCRYPTION_AVAILABLE = True
except ImportError:
    ENCRYPTION_AVAILABLE = False

# Default device IDs (from .env or keychain)
# These should match real paired devices
DEFAULT_ANDROID_DEVICE_ID = "c7bd7e23-b5c1-4dfd-bb62-6a3b7c880760"  # Xiaomi
DEFAULT_ANDROID_DEVICE_NAME = "Xiaomi 2410DPN6CC"
DEFAULT_MACOS_DEVICE_ID = "007E4A95-0E1A-4B10-91FA-87942EFAA68E"  # MacBook Air
DEFAULT_MACOS_DEVICE_NAME = "MacBook Air"

def encrypt_payload(plaintext: bytes, key: bytes, device_id: str) -> Tuple[str, str, str]:
    """Encrypt plaintext using AES-256-GCM.
    
    Args:
        plaintext: The data to encrypt
        key: 32-byte encryption key
        device_id: Device ID for AAD (Additional Authenticated Data)
    
    Returns:
        Tuple of (ciphertext_base64, nonce_base64, tag_base64)
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
    
    # Debug logging
    print(f"🔐 [ENCRYPT] deviceId: {device_id}")
    print(f"🔐 [ENCRYPT] AAD: {device_id} ({len(aad)} bytes)")
    print(f"🔐 [ENCRYPT] AAD hex: {aad.hex()}")
    print(f"🔐 [ENCRYPT] Key size: {len(key)} bytes")
    print(f"🔐 [ENCRYPT] Plaintext size: {len(plaintext)} bytes")
    
    # Encrypt (returns ciphertext + tag)
    encrypted = aesgcm.encrypt(nonce, plaintext, aad)
    
    print(f"🔐 [ENCRYPT] Ciphertext size: {len(encrypted) - 16} bytes")
    print(f"🔐 [ENCRYPT] Nonce size: {len(nonce)} bytes")
    print(f"🔐 [ENCRYPT] Tag size: 16 bytes")
    
    # GCM returns ciphertext + tag (16 bytes at the end)
    ciphertext = encrypted[:-16]
    tag = encrypted[-16:]
    
    # Base64 encode
    ciphertext_b64 = base64.b64encode(ciphertext).decode('utf-8')
    nonce_b64 = base64.b64encode(nonce).decode('utf-8')
    tag_b64 = base64.b64encode(tag).decode('utf-8')
    
    return ciphertext_b64, nonce_b64, tag_b64

def create_text_payload(text: str) -> dict:
    """Create a text clipboard payload.
    
    Args:
        text: The text content
    
    Returns:
        Dictionary with content_type, data, data_base64, and metadata
        Note: macOS's ClipboardPayload.encode() includes both 'data' and 'data_base64'
        fields to match the exact JSON format that macOS produces.
        Key order MUST match Swift's JSONEncoder output: content_type, data, metadata, data_base64
        (Swift encodes in struct field order, but JSONEncoder may reorder keys)
    """
    from collections import OrderedDict
    data_base64 = base64.b64encode(text.encode('utf-8')).decode('utf-8')
    # CRITICAL: Match Swift's JSONEncoder key order exactly!
    # macOS ClipboardPayload.encode() produces: content_type, data, data_base64, metadata
    # (See SyncEngine.swift:179-186 for exact order)
    # This order matters for encryption - different order = different plaintext bytes = BAD_DECRYPT
    return OrderedDict([
        ("content_type", "text"),
        ("data", data_base64),  # macOS includes this field (Data encoded as base64 string in JSON)
        ("data_base64", data_base64),  # data_base64 comes BEFORE metadata in macOS's encode()!
        ("metadata", {}),  # metadata comes AFTER data_base64 in macOS's encode()!
    ])

def create_image_payload(image_data: bytes, image_format: str = "png") -> dict:
    """Create an image clipboard payload.
    
    Args:
        image_data: Raw image bytes
        image_format: Image format (png, jpeg, etc.)
    
    Returns:
        Dictionary with content_type, data, data_base64, and metadata
        Note: macOS's ClipboardPayload.encode() includes both 'data' and 'data_base64'
        fields to match the exact JSON format that macOS produces.
        Key order MUST match Swift's JSONEncoder output: content_type, data, metadata, data_base64
    """
    from collections import OrderedDict
    data_base64 = base64.b64encode(image_data).decode('utf-8')
    # CRITICAL: Match Swift's JSONEncoder key order exactly!
    # macOS ClipboardPayload.encode() produces: content_type, data, data_base64, metadata
    # (See SyncEngine.swift:179-186 for exact order)
    return OrderedDict([
        ("content_type", "image"),
        ("data", data_base64),  # macOS includes this field (Data encoded as base64 string in JSON)
        ("data_base64", data_base64),  # data_base64 comes BEFORE metadata in macOS's encode()!
        ("metadata", OrderedDict([
            ("format", image_format),
            ("size", str(len(image_data)))
        ])),  # metadata comes AFTER data_base64 in macOS's encode()!
    ])

def create_link_payload(url: str) -> dict:
    """Create a link clipboard payload.
    
    Args:
        url: The URL
    
    Returns:
        Dictionary with content_type, data, data_base64, and metadata
        Note: macOS's ClipboardPayload.encode() includes both 'data' and 'data_base64'
        fields to match the exact JSON format that macOS produces.
        Key order MUST match Swift's JSONEncoder output: content_type, data, metadata, data_base64
    """
    from collections import OrderedDict
    url_bytes = url.encode('utf-8')
    data_base64 = base64.b64encode(url_bytes).decode('utf-8')
    # CRITICAL: Match Swift's JSONEncoder key order exactly!
    # macOS ClipboardPayload.encode() produces: content_type, data, data_base64, metadata
    # (See SyncEngine.swift:179-186 for exact order)
    return OrderedDict([
        ("content_type", "link"),
        ("data", data_base64),  # macOS includes this field (Data encoded as base64 string in JSON)
        ("data_base64", data_base64),  # data_base64 comes BEFORE metadata in macOS's encode()!
        ("metadata", {"url": url}),  # metadata comes AFTER data_base64 in macOS's encode()!
    ])

def create_sync_envelope(
    payload: dict,
    sender_device_id: str,
    sender_device_name: str,
    target_device_id: Optional[str] = None,
    encrypted: bool = False,
    key: Optional[bytes] = None
) -> dict:
    """Create a SyncEnvelope in the format expected by the protocol.
    
    Args:
        payload: Clipboard payload (from create_text_payload, create_image_payload, etc.)
        sender_device_id: Device ID of the sender (e.g., Android device ID)
        sender_device_name: Device name of the sender (e.g., "Xiaomi 2410DPN6CC")
        target_device_id: Optional target device ID for routing
        encrypted: Whether to encrypt the payload
        key: Encryption key (32 bytes) if encrypted=True
    
    Returns:
        Dictionary representing the sync envelope
    """
    # Create plaintext payload JSON
    # Use OrderedDict to preserve key order matching Swift struct field order
    # This ensures the JSON bytes match exactly what macOS produces
    # Note: json.dumps preserves OrderedDict order, so no need for sort_keys
    plaintext = json.dumps(payload, separators=(',', ':')).encode('utf-8')
    
    # Encrypt or use plaintext mode
    if encrypted and key:
        if not ENCRYPTION_AVAILABLE:
            raise RuntimeError("Encryption requested but cryptography library not available")
        
        # AAD = sender's device ID (for authentication)
        # Use device ID as-is (no preprocessing) - Android will handle case-insensitive lookup
        ciphertext_b64, nonce_b64, tag_b64 = encrypt_payload(plaintext, key, sender_device_id)
    else:
        # Plaintext mode
        ciphertext_b64 = base64.b64encode(plaintext).decode('utf-8')
        nonce_b64 = ""
        tag_b64 = ""
    
    # Use device ID as-is (no preprocessing) - Android will handle case-insensitive lookup
    # Future keys will be stored as-is, but Android can find old lowercase keys via backward compatibility
    envelope = {
        "id": str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        "version": "1.0",
        "type": "clipboard",
        "payload": {
            "content_type": payload["content_type"],
            "ciphertext": ciphertext_b64,
            "device_id": sender_device_id,  # Use as-is, no preprocessing
            "device_name": sender_device_name,
            "device_platform": "android",  # Simulation scripts mimic Android
            "target": target_device_id,
            "encryption": {
                "algorithm": "AES-256-GCM",
                "nonce": nonce_b64,
                "tag": tag_b64
            }
        }
    }
    
    return envelope

def encode_frame(envelope: dict) -> bytes:
    """Encode envelope using TransportFrameCodec format (4-byte length + JSON).
    
    Args:
        envelope: The sync envelope dictionary
    
    Returns:
        Binary frame data (4-byte length prefix + JSON payload)
    """
    json_str = json.dumps(envelope, separators=(',', ':'))
    json_bytes = json_str.encode('utf-8')
    
    # Prepend 4-byte big-endian length
    length_bytes = struct.pack('>I', len(json_bytes))
    
    return length_bytes + json_bytes

def get_device_config(device_type: str) -> Tuple[str, str]:
    """Get device ID and name for a device type.
    
    Args:
        device_type: "android" or "macos"
    
    Returns:
        Tuple of (device_id, device_name)
    """
    if device_type == "android":
        return (DEFAULT_ANDROID_DEVICE_ID, DEFAULT_ANDROID_DEVICE_NAME)
    elif device_type == "macos":
        return (DEFAULT_MACOS_DEVICE_ID, DEFAULT_MACOS_DEVICE_NAME)
    else:
        raise ValueError(f"Unknown device type: {device_type}")

def load_key_from_keychain(device_id: str) -> Optional[bytes]:
    """Load encryption key from macOS keychain.
    
    Args:
        device_id: Device ID to look up
    
    Returns:
        Key bytes (32 bytes) or None if not found
    """
    import subprocess
    
    # Try exact device ID first
    try:
        # Use shell command to pipe security output through xxd
        result = subprocess.run(
            ['sh', '-c', f'security find-generic-password -w -s com.hypo.clipboard.keys -a "{device_id}" 2>/dev/null | xxd -p -c 32 | tr -d "\\n"'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            key_hex = result.stdout.strip()
            # Take first 64 hex characters (32 bytes)
            if len(key_hex) >= 64:
                key_hex = key_hex[:64]
                key = bytes.fromhex(key_hex)
                if len(key) == 32:
                    return key
    except Exception:
        pass
    
    # Try with android- prefix
    if not device_id.startswith("android-"):
        try:
            result = subprocess.run(
                ['sh', '-c', f'security find-generic-password -w -s com.hypo.clipboard.keys -a "android-{device_id}" 2>/dev/null | xxd -p -c 32 | tr -d "\\n"'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                key_hex = result.stdout.strip()
                # Take first 64 hex characters (32 bytes)
                if len(key_hex) >= 64:
                    key_hex = key_hex[:64]
                    key = bytes.fromhex(key_hex)
                    if len(key) == 32:
                        return key
        except Exception:
            pass
    
    return None

def send_via_cloud_relay(
    payload: dict,
    sender_device_id: str,
    sender_device_name: str,
    target_device_id: Optional[str] = None,
    encrypted: bool = False,
    key: Optional[bytes] = None,
    relay_url: str = "wss://hypo.fly.dev/ws",
    session_device_id: Optional[str] = None,
    force_register: bool = False,
    quiet: bool = False  # Suppress output for speed
) -> bool:
    """Send clipboard message via cloud relay.
    
    Args:
        payload: Clipboard payload (from create_text_payload, create_image_payload, etc.)
        sender_device_id: Device ID of the sender
        sender_device_name: Device name of the sender
        target_device_id: Optional target device ID for routing
        encrypted: Whether to encrypt the payload
        key: Encryption key (32 bytes) if encrypted=True
        relay_url: Cloud relay WebSocket URL
    
    Returns:
        True if message was sent successfully, False otherwise
    """
    try:
        from websocket import create_connection, WebSocketException
        import websocket
    except ImportError:
        print("❌ Error: websocket-client library not installed")
        print("   Install it with: pip3 install websocket-client")
        return False
    
    try:
        if not quiet:
            print(f"🔌 Connecting to cloud relay: {relay_url}...")
        
        # Use session_device_id for WebSocket headers (to avoid session conflicts),
        # but sender_device_id for the envelope payload (for encryption key lookup)
        ws_device_id = session_device_id or sender_device_id
        
        # Create WebSocket connection with required headers
        headers = [
            f"X-Device-Id: {ws_device_id}",
            "X-Device-Platform: android",
            "X-Hypo-Client: 0.2.0",
            "X-Hypo-Environment: production"
        ]
        
        # Add force register header if requested (for testing/debugging)
        # This allows session takeover if the device is already connected
        if force_register:
            headers.append("X-Hypo-Force-Register: true")
            if not quiet:
                print(f"   ⚠️  Force register enabled - will replace existing session if device is connected")
        
        # Reduced timeout for speed (5s instead of 10s)
        ws = create_connection(relay_url, timeout=5, header=headers)
        if not quiet:
            print(f"✅ Connected to cloud relay")
        
        ws.settimeout(5)  # Reduced timeout
        
        # Create sync envelope
        envelope = create_sync_envelope(
            payload=payload,
            sender_device_id=sender_device_id,
            sender_device_name=sender_device_name,
            target_device_id=target_device_id,
            encrypted=encrypted,
            key=key
        )
        if not quiet:
            print(f"📦 Created sync envelope: id={envelope['id'][:8]}...")
            print(f"   Target: {target_device_id or '(broadcast)'}")
        
        # Encode as binary frame
        frame = encode_frame(envelope)
        if not quiet:
            print(f"📤 Sending binary frame: {len(frame)} bytes")
        
        # Send as BINARY message
        ws.send(frame, opcode=websocket.ABNF.OPCODE_BINARY)
        if not quiet:
            print(f"✅ Sent clipboard sync message via relay")
        
        # Close connection immediately (no need to wait)
        ws.close()
        if not quiet:
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

def send_via_lan(
    payload: dict,
    sender_device_id: str,
    sender_device_name: str,
    target_device_id: Optional[str] = None,
    encrypted: bool = False,
    key: Optional[bytes] = None,
    host: str = "localhost",
    port: int = 7010,
    wait_for_reply: bool = False,
    envelope_sender_device_id: Optional[str] = None,  # Device ID for envelope payload (for key lookup)
    quiet: bool = False  # Suppress output for speed
) -> bool:
    """Send clipboard message via LAN WebSocket.
    
    Args:
        payload: Clipboard payload (from create_text_payload, create_image_payload, etc.)
        sender_device_id: Device ID of the sender (for WebSocket headers)
        sender_device_name: Device name of the sender
        target_device_id: Optional target device ID for routing
        encrypted: Whether to encrypt the payload
        key: Encryption key (32 bytes) if encrypted=True
        host: LAN WebSocket server host
        port: LAN WebSocket server port
        wait_for_reply: Whether to wait for a reply from the server
        envelope_sender_device_id: Optional device ID to use in the envelope payload.
                                   If None, sender_device_id is used.
                                   This is useful when sender_device_id is a test ID,
                                   but encryption requires a real device ID for key lookup.
    
    Returns:
        True if message was sent successfully, False otherwise
    """
    try:
        from websocket import create_connection, WebSocketException
    except ImportError:
        print("❌ Error: websocket-client library not installed")
        print("   Install it with: pip3 install websocket-client")
        return False
    
    url = f"ws://{host}:{port}"
    
    try:
        print(f"🔌 Connecting to {url}...")
        
        # Real Android sends X-Device-Id and X-Device-Platform headers
        # Match this behavior in the simulation script
        headers = [
            f"X-Device-Id: {sender_device_id}",
            "X-Device-Platform: android"
        ]
        
        # Reduced timeout for speed (3s instead of 10s)
        ws = create_connection(url, timeout=3, header=headers)
        if not quiet:
            print(f"✅ Connected to WebSocket server")
            print(f"   Headers: X-Device-Id={sender_device_id}, X-Device-Platform=android")
        
        ws.settimeout(3)  # Reduced timeout
        
        # Determine which device ID to use in the envelope payload
        # The device_id in the envelope must match a device ID that has a key stored
        # macOS validates by: key = keyProvider.key(for: envelope.deviceId)
        # If envelope_sender_device_id is provided, use it (for backward compatibility)
        # Otherwise, use sender_device_id (should be real UUID with matching key)
        final_envelope_sender_id = envelope_sender_device_id if envelope_sender_device_id else sender_device_id
        
        # Create sync envelope
        envelope = create_sync_envelope(
            payload=payload,
            sender_device_id=final_envelope_sender_id,
            sender_device_name=sender_device_name,
            target_device_id=target_device_id,
            encrypted=encrypted,
            key=key
        )
        if not quiet:
            print(f"📤 Created sync envelope: id={envelope['id'][:8]}...")
            if encrypted:
                print(f"   🔒 Encrypted (envelope device_id: {final_envelope_sender_id})")
            else:
                print(f"   📝 Plaintext mode")
        
        # Encode frame
        frame = encode_frame(envelope)
        if not quiet:
            print(f"📤 Frame payload: {len(frame)} bytes")
        
        # Send as WebSocket binary frame
        # CRITICAL: The websocket-client library may buffer frames.
        # We need to ensure the binary frame is sent BEFORE we close the connection.
        import websocket
        import time
        import socket
        
        try:
            if not quiet:
                print(f"📤 Sending {len(frame)} bytes as binary frame...")
            
            # Explicitly send as binary frame with OPCODE_BINARY
            # The websocket-client library needs explicit opcode to ensure binary frames
            import websocket
            ws.send(frame, opcode=websocket.ABNF.OPCODE_BINARY)
            
            # CRITICAL FIX: Force the underlying socket to flush
            # websocket-client doesn't expose flush(), but we can access the underlying socket
            if hasattr(ws, 'sock') and ws.sock:
                try:
                    # Get the underlying socket and flush it
                    sock = ws.sock
                    if hasattr(sock, 'flush'):
                        sock.flush()
                    # Force TCP_NODELAY to disable Nagle's algorithm (send immediately)
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                except Exception:
                    pass  # Ignore errors for speed
            
            if not quiet:
                print(f"✅ Binary frame sent: {len(frame)} bytes")
            
        except Exception as e:
            print(f"❌ Error sending frame: {e}")
            import traceback
            traceback.print_exc()
            return False
        
        # CRITICAL: Don't close immediately after sending
        # Give the server time to receive and process the frame
        # Also, if we close too quickly, the close frame might be sent before the binary frame
        
        if wait_for_reply:
            if not quiet:
                print(f"\n📥 Waiting for server reply (3s timeout)...")
            try:
                ws.settimeout(3)  # Reduced timeout
                reply = ws.recv()
                if not quiet:
                    if isinstance(reply, bytes):
                        print(f"📥 Received binary reply: {len(reply)} bytes")
                    else:
                        print(f"📥 Received text reply: {reply}")
            except Exception:
                if not quiet:
                    print(f"⚠️ No reply received")
        # No need to wait - close immediately (TCP will handle delivery)
        
        # Now close the connection (this sends a CLOSE frame)
        ws.close()
        if not quiet:
            print(f"✅ Connection closed")
        
        return True
        
    except WebSocketException as e:
        print(f"❌ WebSocket error: {e}")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

