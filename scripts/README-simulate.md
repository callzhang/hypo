# Simulate Android Clipboard Copy

The `simulate-android-copy.py` script simulates an Android device sending clipboard data to the macOS WebSocket server. This is useful for testing the sync functionality without manually copying text on Android.

## SMS-to-Clipboard Testing

### Quick Test Script

Use `test-sms-clipboard.sh` for comprehensive SMS testing:

```bash
# Get device ID first
adb devices -l

# Run test script
./scripts/test-sms-clipboard.sh <device_id>
```

This script will:
- Check SMS permission status
- Verify SMS receiver registration
- Monitor logs for SMS reception and clipboard copy
- Provide instructions for emulator vs physical device testing

### Simulate SMS (Emulator Only)

For Android emulators, use `simulate-sms.sh`:

```bash
# Send test SMS via emulator
./scripts/simulate-sms.sh <device_id> "+1234567890" "Test SMS message"
```

**Note**: This only works on emulators. For physical devices, send a real SMS from another phone.

### Manual Testing Steps

1. **Grant SMS Permission**:
   - Open Hypo app → Settings
   - Find "SMS Auto-Sync" section
   - Click "Grant Permission" if not granted

2. **Send Test SMS**:
   - **Emulator**: `adb -s <device_id> emu sms send +1234567890 "Test message"`
   - **Physical Device**: Send SMS from another phone

3. **Monitor Logs**:
   ```bash
   adb -s <device_id> logcat | grep -E "SmsReceiver|ClipboardListener"
   ```

4. **Verify Clipboard**:
   - Check Android clipboard history in Hypo app
   - Verify SMS appears with format: "From: <number>\n<message>"
   - Check if SMS syncs to macOS (if devices are paired)

### Expected Log Output

When SMS is received, you should see:
```
SmsReceiver: 📱 Received SMS from +1234567890: Test message...
SmsReceiver: ✅ SMS content copied to clipboard (XX chars)
ClipboardListener: 📋 Clipboard changed, processing...
```

### Troubleshooting

- **SMS not received**: Check Android version (Android 10+ has restrictions)
- **Permission denied**: Grant RECEIVE_SMS permission in Settings
- **Not copying to clipboard**: Check logs for SecurityException warnings
- **Not syncing**: Verify clipboard sync service is running and devices are paired

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
- `--target-platform`: Target platform (`macos` or `android`) - uses default device IDs if `--target-device-id` not specified
- `--target-device-id`: Target device ID for the specified platform (required if `--target-platform` is specified and you want a custom device ID)
- `--encrypted`: Encrypt the message (requires `--key` or `--key-file`)
- `--key`: Encryption key as hex string (32 bytes = 64 hex chars)
- `--key-file`: Path to file containing encryption key (32 bytes binary or hex string)

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

