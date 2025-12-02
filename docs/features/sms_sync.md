# SMS Auto-Sync Feature

## Overview

The SMS auto-sync feature automatically copies incoming SMS messages to the clipboard, which then gets synced to macOS via the existing clipboard sync mechanism.

## How It Works

1. **SMS Reception**: `SmsReceiver` listens for incoming SMS broadcasts
2. **Auto-Copy**: SMS content is automatically copied to clipboard with format: `From: <sender>\n<message>`
3. **Auto-Sync**: Existing `ClipboardListener` detects the clipboard change and syncs to macOS

## Implementation

### Components

- **SmsReceiver** (`service/SmsReceiver.kt`): BroadcastReceiver that listens for `SMS_RECEIVED` broadcasts
- **AndroidManifest.xml**: Registers receiver with `RECEIVE_SMS` permission

### SMS Format

When an SMS is received, it's copied to clipboard in this format:
```
From: +1234567890
This is the SMS message content
```

## Android Version Limitations

### Android 9 and Below (API 28-)
- ✅ **Fully Supported**: SMS receiver works without restrictions
- No special setup required

### Android 10+ (API 29+)
- ⚠️ **Restricted**: SMS access is limited for security reasons
- **Option 1**: Set Hypo as the default SMS app (not recommended - breaks SMS functionality)
- **Option 2**: Use Accessibility Service (limited SMS access, may not work reliably)
- **Option 3**: User manually grants SMS permission (may not be sufficient on all devices)

### Current Behavior
- The receiver will attempt to process SMS messages
- If access is denied (SecurityException), it logs a warning but doesn't crash
- Users on Android 10+ may need to manually copy SMS if auto-copy fails

## Permissions

### Required Permissions
- `RECEIVE_SMS`: Required to receive SMS broadcast intents
- `BROADCAST_SMS`: Required for the receiver to receive SMS broadcasts (system permission)

### Runtime Permissions
- On Android 6.0+ (API 23+), `RECEIVE_SMS` is a dangerous permission but is automatically granted at install time (not a runtime permission)
- However, Android 10+ restrictions may still apply

## User Experience

### Automatic Flow
1. User receives SMS on Android device
2. SMS content is automatically copied to clipboard
3. Clipboard sync service detects change
4. SMS content is synced to macOS within ~1 second
5. User can see SMS in macOS clipboard history

### Manual Fallback
If auto-copy fails (Android 10+ restrictions):
1. User receives SMS notification
2. User manually opens SMS app and copies content
3. Clipboard sync service detects manual copy
4. Content is synced to macOS

## Privacy & Security

- SMS content is handled the same way as any clipboard content
- Encrypted end-to-end when syncing to macOS
- No SMS content is stored permanently (only in clipboard history)
- Users can clear clipboard history to remove SMS content

## Testing

### Test on Android 9 or Below
1. Send test SMS to device
2. Verify SMS appears in clipboard history
3. Verify SMS syncs to macOS

### Test on Android 10+
1. Send test SMS to device
2. Check logs for SecurityException warnings
3. If auto-copy fails, verify manual copy still works

## Future Improvements

1. **Notification Action**: Add "Copy to Clipboard" action in SMS notifications
2. **Selective Sync**: Allow users to choose which SMS to sync (filter by sender, keywords, etc.)
3. **SMS Formatting**: Customize SMS format (e.g., include timestamp, sender name resolution)
4. **Batch Processing**: Handle multiple SMS messages more intelligently

## Troubleshooting

### SMS Not Auto-Copying
- **Check Android version**: Android 10+ has restrictions
- **Check logs**: Look for `SmsReceiver` logs and SecurityException warnings
- **Verify permission**: Ensure `RECEIVE_SMS` permission is granted
- **Test manual copy**: If manual copy works, sync mechanism is fine - issue is SMS access

### SMS Copied But Not Syncing
- **Check clipboard sync**: Verify clipboard sync service is running
- **Check network**: Ensure device is connected to network (LAN or cloud)
- **Check pairing**: Verify devices are paired
- **Check logs**: Look for `ClipboardListener` and `SyncCoordinator` logs


