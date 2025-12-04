package com.hypo.clipboard.data.local

import androidx.paging.PagingSource
import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import kotlinx.coroutines.flow.Flow
import java.time.Instant

@Dao
interface ClipboardDao {
    // For list views, exclude content for IMAGE and FILE types to avoid CursorWindow overflow
    // Content will be loaded lazily when needed (copying or viewing details)
    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        ORDER BY created_at DESC
    """)
    fun observe(): Flow<List<ClipboardEntity>>
    
    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        ORDER BY created_at DESC 
        LIMIT :limit
    """)
    fun observeWithLimit(limit: Int = 200): Flow<List<ClipboardEntity>>

    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        ORDER BY created_at DESC
    """)
    fun observePaged(): PagingSource<Int, ClipboardEntity>

    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        WHERE is_pinned = 1 
        ORDER BY created_at DESC
    """)
    fun observePinned(): Flow<List<ClipboardEntity>>

    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        WHERE content LIKE '%' || :query || '%' OR preview LIKE '%' || :query || '%'
        ORDER BY created_at DESC 
        LIMIT :limit
    """)
    fun search(query: String, limit: Int = 50): Flow<List<ClipboardEntity>>

    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        WHERE device_id = :deviceId 
        ORDER BY created_at DESC 
        LIMIT :limit
    """)
    fun observeByDevice(deviceId: String, limit: Int = 100): Flow<List<ClipboardEntity>>

    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        WHERE type = :type 
        ORDER BY created_at DESC 
        LIMIT :limit
    """)
    fun observeByType(type: String, limit: Int = 100): Flow<List<ClipboardEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: ClipboardEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<ClipboardEntity>)

    @Delete
    suspend fun delete(entity: ClipboardEntity)

    @Query("DELETE FROM clipboard_items WHERE id = :id")
    suspend fun deleteById(id: String)

    @Query("DELETE FROM clipboard_items WHERE id IN (:ids)")
    suspend fun deleteByIds(ids: List<String>)

    @Query("DELETE FROM clipboard_items")
    suspend fun clear()

    @Query("DELETE FROM clipboard_items WHERE created_at < :cutoff AND is_pinned = 0")
    suspend fun deleteOlderThan(cutoff: Instant)

    @Query("""
        DELETE FROM clipboard_items 
        WHERE id NOT IN (
            SELECT id FROM clipboard_items
            WHERE is_pinned = 1
            UNION
            SELECT id FROM (
                SELECT id FROM clipboard_items
                ORDER BY created_at DESC
                LIMIT :keepCount
            )
        )
    """)
    suspend fun trimToSize(keepCount: Int)

    // findById needs full content for loading on-demand
    // For large IMAGE/FILE items, we need to load content separately to avoid CursorWindow overflow
    // First get the item without content, then load content if needed
    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        WHERE id = :id 
        LIMIT 1
    """)
    suspend fun findByIdWithoutContent(id: String): ClipboardEntity?
    
    // Load only the content field for a specific item (for large IMAGE/FILE items)
    @Query("SELECT content FROM clipboard_items WHERE id = :id LIMIT 1")
    suspend fun findContentById(id: String): String?
    
    // Legacy findById - kept for backward compatibility but may fail for large items
    @Query("SELECT * FROM clipboard_items WHERE id = :id LIMIT 1")
    suspend fun findById(id: String): ClipboardEntity?

    @Query("SELECT COUNT(*) FROM clipboard_items")
    suspend fun getCount(): Int

    @Query("SELECT COUNT(*) FROM clipboard_items WHERE is_pinned = 1")
    suspend fun getPinnedCount(): Int

    @Query("UPDATE clipboard_items SET is_pinned = :isPinned WHERE id = :id")
    suspend fun updatePinnedStatus(id: String, isPinned: Boolean)
    
    // Get the latest (most recent) clipboard entry
    // Exclude content for IMAGE/FILE types to avoid CursorWindow overflow
    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        ORDER BY created_at DESC 
        LIMIT 1
    """)
    suspend fun getLatestEntry(): ClipboardEntity?
    
    // Find matching entry by content and type (excluding the latest entry)
    // For IMAGE/FILE types, exclude content from SELECT to avoid CursorWindow overflow
    // We compare content in the WHERE clause, but don't load it into the result
    @Query("""
        SELECT 
            id, type, 
            CASE 
                WHEN type IN ('IMAGE', 'FILE') THEN '' 
                ELSE content 
            END as content,
            preview, metadata, device_id, device_name, created_at, is_pinned, is_encrypted, transport_origin
        FROM clipboard_items 
        WHERE content = :content 
        AND type = :type 
        AND id != (SELECT id FROM clipboard_items ORDER BY created_at DESC LIMIT 1)
        ORDER BY created_at DESC 
        LIMIT 1
    """)
    suspend fun findMatchingEntryInHistory(content: String, type: String): ClipboardEntity?
    
    // Update timestamp to move entry to top
    @Query("UPDATE clipboard_items SET created_at = :newTimestamp WHERE id = :id")
    suspend fun updateTimestamp(id: String, newTimestamp: Instant)
    
    // Check for duplicate clipboard items (same content, type, device within time window)
    @Query("""
        SELECT COUNT(*) FROM clipboard_items 
        WHERE content = :content 
        AND type = :type 
        AND device_id = :deviceId 
        AND created_at >= :since
    """)
    suspend fun countRecentDuplicates(content: String, type: String, deviceId: String, since: Instant): Int

    // Batch operations for better performance
    @Transaction
    suspend fun replaceAll(entities: List<ClipboardEntity>) {
        clear()
        upsertAll(entities)
    }

    @Transaction
    suspend fun cleanupOldEntries(maxEntries: Int, maxAge: Instant) {
        deleteOlderThan(maxAge)
        trimToSize(maxEntries)
    }
}
