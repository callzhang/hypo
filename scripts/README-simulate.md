# Simulate Android Clipboard Copy

The `simulate-android-copy.py` script simulates an Android device sending clipboard data to the macOS WebSocket server. This is useful for testing the sync functionality without manually copying text on Android.

## Installation

Install the required Python library:

```bash
pip3 install websocket-client
```

## Usage

Basic usage (sends to localhost:7010):

```bash
python3 scripts/simulate-android-copy.py --text "Hello from script!"
```

Send to a specific host:

```bash
python3 scripts/simulate-android-copy.py --host 192.168.1.100 --port 7010 --text "Test message"
```

Customize device info:

```bash
python3 scripts/simulate-android-copy.py \
  --text "Custom message" \
  --device-name "My Test Device" \
  --device-id "android-test-123"
```

## Options

- `--host`: macOS WebSocket server host (default: localhost)
- `--port`: macOS WebSocket server port (default: 7010)
- `--text`: Text to send in clipboard sync (default: "Test clipboard from script")
- `--device-id`: Device ID to use (default: auto-generated android-UUID)
- `--device-name`: Device name to use (default: "Test Android Device")
- `--target`: Target device ID (optional)

## Example

```bash
# Send a test message
python3 scripts/simulate-android-copy.py --text "Testing clipboard sync!"

# Send to remote macOS
python3 scripts/simulate-android-copy.py \
  --host 192.168.1.50 \
  --text "Hello from test script"
```

## How It Works

1. Connects to the macOS WebSocket server (ws://host:port)
2. Creates a `SyncEnvelope` in the same format as Android
3. Encodes it using `TransportFrameCodec` format (4-byte length + JSON)
4. Sends it as a WebSocket binary frame (opcode 2)
5. Closes the connection

The script uses plaintext mode for testing (empty nonce/tag). In production, Android would encrypt the payload with AES-256-GCM.

