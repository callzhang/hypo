# History Management Logic Comparison: macOS vs Android

## Overview
This document describes the unified clipboard history management logic used by both macOS and Android platforms.

**Status**: ✅ **ALIGNED** - Both platforms use identical logic for duplicate detection and content matching.

---

## 1. Duplicate Detection Logic

### Unified Logic (Both Platforms)
- **No time windows** - Duplicate detection is based on content matching only
- **Simplified checks** (in order):
  1. **Current clipboard match**: If new entry matches the latest entry (current clipboard) → **discard**
  2. **History match**: If new entry matches an entry in history (excluding latest) → **move matching entry to top** (update timestamp) and **copy to clipboard**
  3. **Otherwise**: Add new entry to history

### Implementation

**macOS** (`HistoryStore.swift`):
```swift
// Check if matches current clipboard (latest entry)
if let latestEntry = entries.first {
    if entry.matchesContent(latestEntry) {
        return entries  // Discard
    }
}

// Check if matches something in history (excluding the latest entry)
let historyEntries = Array(entries.dropFirst())
if let matchingEntry = historyEntries.first(where: { entry.matchesContent($0) }) {
    // Move to top by updating timestamp
    entries[index].timestamp = now
    sortEntries()
    return entries
}

// Add new entry
entries.append(entry)
```

**Android** (`SyncCoordinator.kt`):
```kotlin
val latestEntry = repository.getLatestEntry()
if (latestEntry != null && eventItem.matchesContent(latestEntry)) {
    continue  // Discard
}

val matchingEntry = repository.findMatchingEntryInHistory(eventItem)
if (matchingEntry != null) {
    repository.updateTimestamp(matchingEntry.id, Instant.now())
    continue  // Move to top
}

repository.upsert(item)  // Add new entry
```

**✅ CONSISTENT**: Both platforms use identical simplified logic with no time windows.

---

## 2. Content Matching Logic

### Unified Matching Function (Both Platforms)

Both platforms use the same matching logic via `matchesContent()` function:

**Matching Criteria** (in order):
1. **Content type** - Must match (text, link, image, file)
2. **Content length** - Must match
3. **First 1KB hash** - Hash of first 1KB of content data must match

**Note**: Metadata (device UUID, timestamp) is **stored** but **not used** for matching. This ensures that the same content from different devices or at different times is correctly identified as a duplicate.

### Implementation

**macOS** (`ClipboardEntry.swift`):
```swift
func matchesContent(_ other: ClipboardEntry) -> Bool {
    // 1. Check content type
    switch (content, other.content) {
    case (.text(let text1), .text(let text2)):
        if text1.count != text2.count { return false }
        return hashFirst1KB(Data(text1.utf8)) == hashFirst1KB(Data(text2.utf8))
    case (.image(let meta1), .image(let meta2)):
        if meta1.byteSize != meta2.byteSize { return false }
        return hashFirst1KB(meta1.data ?? Data()) == hashFirst1KB(meta2.data ?? Data())
    // ... similar for link and file
    }
}
```

**Android** (`ClipboardItem.kt`):
```kotlin
fun matchesContent(other: ClipboardItem): Boolean {
    if (type != other.type) return false
    if (content.length != other.content.length) return false
    val hash1 = hashFirst1KB(content.toByteArray(Charsets.UTF_8))
    val hash2 = hashFirst1KB(other.content.toByteArray(Charsets.UTF_8))
    return hash1 == hash2
}
```

**✅ CONSISTENT**: Both platforms use identical matching logic (content type → length → first 1KB hash).

---

## 3. History Insertion Flow

### Unified Flow (Both Platforms)

**Simplified insertion logic** (no time windows, no signature tracking):

1. **Check if matches current clipboard** → discard (ignore)
2. **Check if matches history** → move matching entry to top (update timestamp) and copy to clipboard
3. **Otherwise** → add new entry

**✅ CONSISTENT**: Both platforms use identical simplified insertion flow.

---

## 4. Sorting Logic

### macOS
```swift
private func sortEntries() {
    entries.sort { lhs, rhs in
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned  // Pinned first
        }
        return lhs.timestamp > rhs.timestamp  // Newest first
    }
}
```
- **Pinned items first**, then sorted by timestamp (newest first)

### Android
```sql
SELECT * FROM clipboard_items ORDER BY created_at DESC
```
- **No explicit pinned sorting** in base query
- Pinned items query exists separately: `SELECT * FROM clipboard_items WHERE is_pinned = 1 ORDER BY created_at DESC`
- UI layer may handle pinned item display separately

**Note**: Both platforms keep pinned items in the list. macOS sorts them to the top, while Android may handle display in the UI layer. This is a platform-appropriate implementation difference.

---

## 5. History Limit/Trimming

### Unified Logic (Both Platforms)

- **Default limit**: 200 entries
- **Pinned items**: Explicitly protected during trim (keep all pinned items + most recent unpinned items up to limit)

### Implementation

**macOS** (`HistoryStore.swift`):
```swift
private func trimIfNeeded() {
    if entries.count > maxEntries {
        // Protect pinned items during trim
        let pinnedItems = entries.filter { $0.isPinned }
        let unpinnedItems = entries.filter { !$0.isPinned }
        let keepUnpinnedCount = max(0, maxEntries - pinnedItems.count)
        let sortedUnpinned = unpinnedItems.sorted { $0.timestamp > $1.timestamp }
        let keepUnpinned = Array(sortedUnpinned.prefix(keepUnpinnedCount))
        entries = pinnedItems + keepUnpinned
        sortEntries()
    }
}
```

**Android** (`ClipboardDao.kt`):
```sql
DELETE FROM clipboard_items 
WHERE id NOT IN (
    SELECT id FROM clipboard_items WHERE is_pinned = 1
    UNION
    SELECT id FROM (SELECT id FROM clipboard_items ORDER BY created_at DESC LIMIT :keepCount)
)
```

**✅ CONSISTENT**: Both platforms explicitly protect pinned items during trimming.

---

## 6. Remote vs Local Entry Handling

### Unified Logic (Both Platforms)

- **No special remote handling**: All entries are treated the same regardless of source device
- **Device ID tracking**: Both platforms track `deviceId` and `deviceName` for display purposes only
- **Content-based matching**: Duplicate detection is based on content only, not device origin

**Rationale**: Simplified approach - if content matches, it's a duplicate regardless of source. This prevents duplicates from dual-send (LAN + cloud) scenarios without needing time windows or device-specific logic.

**✅ CONSISTENT**: Both platforms use simple, content-based duplicate detection without special remote handling.

---

## 7. Duplicate Window Timing

### Unified Logic (Both Platforms)

- **No time windows**: Duplicate detection is based on content matching only, not time-based windows
- **Rationale**: Content-based matching (type → length → first 1KB hash) is sufficient to detect duplicates without needing time windows

**✅ CONSISTENT**: Both platforms removed time-based duplicate detection windows.

---

## 9. Persistence Strategy

### Platform-Appropriate Implementation

**macOS**:
- **Storage**: UserDefaults (JSON-encoded array)
- **Persistence trigger**: After every insert, update, or delete
- **Synchronous**: Persists immediately on main thread
- **Rationale**: Appropriate for macOS, simple key-value storage

**Android**:
- **Storage**: Room database (SQLite)
- **Persistence trigger**: Automatic (Room handles it)
- **Asynchronous**: Database operations are suspend functions
- **Rationale**: Appropriate for Android, provides better performance and query capabilities

**✅ APPROPRIATE**: Both platforms use storage mechanisms appropriate for their respective platforms.

---

## 10. History Match Logic (Moving to Top)

### Unified Logic (Both Platforms)

When a new entry matches an existing entry in history (excluding the latest/current clipboard entry):

1. **Update timestamp** of matching entry to current time
2. **Move to top** via sorting (macOS) or database update (Android)
3. **Copy to clipboard** (implicit - the matching entry becomes the latest)

**Implementation**:

**macOS**:
```swift
if let matchingEntry = historyEntries.first(where: { entry.matchesContent($0) }) {
    entries[index].timestamp = now
    sortEntries()  // Moves to top
    persistEntries()
}
```

**Android**:
```kotlin
val matchingEntry = repository.findMatchingEntryInHistory(eventItem)
if (matchingEntry != null) {
    repository.updateTimestamp(matchingEntry.id, Instant.now())  // Moves to top via ORDER BY
}
```

**✅ CONSISTENT**: Both platforms move matching history entries to the top by updating the timestamp.

---

## 8. Content Hash Generation

### Unified Logic (Both Platforms)

Both platforms use the same hash generation for content matching:

**Hash Algorithm**: First 1KB hash
- Sample first 1024 bytes (or less if content is shorter)
- Use simple hash function: `hash = hash * 31 + byte`
- Same algorithm on both platforms ensures consistent matching

**Implementation**:

**macOS**:
```swift
private func hashFirst1KB(_ data: Data) -> Int {
    let sampleSize = min(1024, data.count)
    var hash = 0
    for byte in data.prefix(sampleSize) {
        hash = hash &* 31 &+ Int(byte)
    }
    return hash
}
```

**Android**:
```kotlin
private fun hashFirst1KB(data: ByteArray): Int {
    val sampleSize = minOf(1024, data.size)
    var hash = 0
    for (i in 0 until sampleSize) {
        hash = hash * 31 + (data[i].toInt() and 0xFF)
    }
    return hash
}
```

**✅ CONSISTENT**: Both platforms use identical hash generation algorithm (first 1KB, same hash function).

---

## Summary

### ✅ Unified Logic (Both Platforms)

All critical logic is now **aligned** between macOS and Android:

1. **Duplicate Detection**: ✅ **IDENTICAL**
   - No time windows
   - Check if matches current clipboard → discard
   - Check if matches history → move to top (and copy to clipboard)
   - Otherwise → add new entry

2. **Content Matching**: ✅ **IDENTICAL**
   - Content type check
   - Content length check
   - First 1KB hash comparison
   - Metadata (device UUID, timestamp) stored but **not used** for matching

3. **Pinned Item Protection**: ✅ **IDENTICAL**
   - Both platforms explicitly protect pinned items during trim
   - Keep all pinned items + most recent unpinned items up to limit

4. **Hash Generation**: ✅ **IDENTICAL**
   - Same algorithm: first 1KB hash using `hash = hash * 31 + byte`
   - Consistent across all content types (text, link, image, file)

### Platform-Appropriate Differences

These differences are intentional and appropriate for each platform:

1. **Storage**: UserDefaults (macOS) vs Room database (Android)
2. **Concurrency**: Actor-based (macOS) vs Coroutine-based (Android)
3. **Sorting**: In-memory sort (macOS) vs SQL ORDER BY (Android)

### Implementation Status

- ✅ **macOS**: Simplified duplicate detection, unified matching, pinned item protection
- ✅ **Android**: Simplified duplicate detection, unified matching, pinned item protection
- ✅ **Both**: No time windows, content-based matching only, identical logic

**Result**: Both platforms now behave identically for duplicate detection and content matching, ensuring consistent user experience across devices.

