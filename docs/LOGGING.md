# Logging Guide

Hypo uses `os_log` (via `HypoLogger`) for system-integrated logging on macOS. All logs are visible in Console.app and via the `log` command-line tool.

## Viewing Logs

### Method 1: Console.app (Recommended)

1. Open **Console.app** (Applications → Utilities → Console)
2. In the sidebar, select your Mac under "Devices"
3. Use the search bar to filter logs:
   - **Subsystem**: `com.hypo.clipboard`
   - **Category**: Filter by specific categories (e.g., `LanWebSocketServer`, `TransportManager`, `SyncEngine`)
   - **Search terms**: Use keywords like "pairing", "connection", "error", etc.

**Tips:**
- Enable "Include Info Messages" and "Include Debug Messages" in Console preferences
- Use the filter bar to narrow down by subsystem/category
- Logs are color-coded by level (debug=gray, info=blue, error=red)

### Method 2: Command Line (`log` command)

View recent logs:
```bash
# View all Hypo logs from the last hour
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 1h

# View logs for a specific category
log show --predicate 'subsystem == "com.hypo.clipboard" && category == "LanWebSocketServer"' --last 1h

# View only errors
log show --predicate 'subsystem == "com.hypo.clipboard" && eventType == "errorEvent"' --last 1h

# Stream logs in real-time
log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug
```

### Method 3: Filter by Process

If the app is running:
```bash
# Find the process ID
ps aux | grep HypoMenuBar

# Stream logs for that process
log stream --predicate 'processID == <PID>' --level debug
```

## Log Categories

Each component has its own category for easier filtering:

| Category | Component |
|----------|-----------|
| `LanWebSocketServer` | WebSocket server for LAN connections |
| `TransportManager` | Transport layer management |
| `SyncEngine` | Clipboard sync engine |
| `ClipboardMonitor` | Clipboard change monitoring |
| `ConnectionStatusProber` | Network connectivity checking |
| `HistoryStore` | Clipboard history storage |
| `PairingSession` | Device pairing |
| `IncomingClipboardHandler` | Incoming clipboard data handler |

## Log Levels

- **Debug**: Detailed diagnostic information (verbose)
- **Info**: General informational messages (default)
- **Notice**: Important but not error conditions
- **Warning**: Warning conditions
- **Error**: Error conditions
- **Fault**: Critical errors

## Filtering Examples

### View pairing-related logs:
```bash
log show --predicate 'subsystem == "com.hypo.clipboard" && composedMessage CONTAINS "pairing"' --last 1h
```

### View connection errors:
```bash
log show --predicate 'subsystem == "com.hypo.clipboard" && (eventType == "errorEvent" || composedMessage CONTAINS "error")' --last 1h
```

### View WebSocket server activity:
```bash
log stream --predicate 'subsystem == "com.hypo.clipboard" && category == "LanWebSocketServer"' --level debug
```

## Debugging Tips

1. **Enable Debug Logging**: Debug messages are only shown if you enable "Include Debug Messages" in Console.app or use `--level debug` with `log stream`

2. **Real-time Monitoring**: Use `log stream` to watch logs as they happen:
   ```bash
   log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug --style compact
   ```

3. **Export Logs**: Save logs to a file for analysis:
   ```bash
   log show --predicate 'subsystem == "com.hypo.clipboard"' --last 1h > hypo_logs.txt
   ```

4. **Search for Specific Events**: 
   ```bash
   # Find all pairing attempts
   log show --predicate 'subsystem == "com.hypo.clipboard" && composedMessage CONTAINS "pairing"' --last 24h
   
   # Find all errors
   log show --predicate 'subsystem == "com.hypo.clipboard" && eventType == "errorEvent"' --last 24h
   ```

## Log Privacy

All log messages use `.public` privacy level, meaning they're fully visible in logs. Sensitive data (like device IDs, keys) are logged but can be filtered if needed.

## Troubleshooting

### Logs not appearing?
1. Ensure the app is running
2. Check that you're filtering by the correct subsystem: `com.hypo.clipboard`
3. Enable debug-level logging if looking for debug messages
4. Check Console.app preferences to ensure all log levels are enabled

### Too many logs?
- Use category filters to narrow down (e.g., `category == "LanWebSocketServer"`)
- Filter by log level (e.g., `eventType == "errorEvent"` for errors only)
- Use time-based filtering with `--last` option

### Need more verbose logging?
- Debug-level logs are available but may be filtered by default
- Use `--level debug` with `log stream` or enable in Console.app preferences

## Migration from File Logging

Previously, Hypo wrote logs to `/tmp/hypo_debug.log`. This file-based logging has been removed in favor of system logging. All logs are now in the unified system log and can be accessed via Console.app or the `log` command.

