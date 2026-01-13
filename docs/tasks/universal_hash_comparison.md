# Universal Hash Comparison

**Status**: Completed
**Date**: 2026-01-12
**Priority**: High

## Objective
Implement hash-based comparison for ALL clipboard message types (Text, Link, Image, File) on both Android and macOS to ensure consistent duplicate detection and reliable syncing.

## Implementation Results

### 1. macOS (`HistoryStore.swift`)
- [x] **Sending**: Calculated SHA-256 hash for `text`, `link`, and `image` types and added to `metadata`.
- [x] **Receiving**: `ClipboardEntry.matchesContent` inherently uses SHA-256 hash of content (calculated on-the-fly) which aligns with the sender's logic.

### 2. Android
- [x] **Sending**: Verified `ClipboardParser.kt` already includes SHA-256 hash for `TEXT` and `LINK` types (and `FILE`/`IMAGE`).
- [x] **Receiving (`ClipboardItem.kt`)**: Refactored `matchesContent` to:
    1. **Primary**: Check `metadata["hash"]` for ALL types. If both have hashes, this is definitive.
    2. **Image/File Fallback**: If hashes missing, use empty check & base64 decode check.
    3. **Generic Fallback**: If hashes missing, use content length & SHA-256 of content string.

## Outcome
- Duplicate detection is now **O(1)** for all types when hashes are present.
- Reliable separation of files with same empty content string (via hash).
- Consistent behavior across all content types.
