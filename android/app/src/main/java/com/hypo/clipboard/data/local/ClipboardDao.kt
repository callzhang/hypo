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
    @Query("SELECT * FROM clipboard_items ORDER BY created_at DESC")
    fun observe(): Flow<List<ClipboardEntity>>
    
    @Query("SELECT * FROM clipboard_items ORDER BY created_at DESC LIMIT :limit")
    fun observeWithLimit(limit: Int = 200): Flow<List<ClipboardEntity>>

    @Query("SELECT * FROM clipboard_items ORDER BY created_at DESC")
    fun observePaged(): PagingSource<Int, ClipboardEntity>

    @Query("SELECT * FROM clipboard_items WHERE is_pinned = 1 ORDER BY created_at DESC")
    fun observePinned(): Flow<List<ClipboardEntity>>

    @Query("""
        SELECT * FROM clipboard_items 
        WHERE content LIKE '%' || :query || '%' OR preview LIKE '%' || :query || '%'
        ORDER BY created_at DESC 
        LIMIT :limit
    """)
    fun search(query: String, limit: Int = 50): Flow<List<ClipboardEntity>>

    @Query("SELECT * FROM clipboard_items WHERE device_id = :deviceId ORDER BY created_at DESC LIMIT :limit")
    fun observeByDevice(deviceId: String, limit: Int = 100): Flow<List<ClipboardEntity>>

    @Query("SELECT * FROM clipboard_items WHERE type = :type ORDER BY created_at DESC LIMIT :limit")
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

    @Query("SELECT * FROM clipboard_items WHERE id = :id LIMIT 1")
    suspend fun findById(id: String): ClipboardEntity?

    @Query("SELECT COUNT(*) FROM clipboard_items")
    suspend fun getCount(): Int

    @Query("SELECT COUNT(*) FROM clipboard_items WHERE is_pinned = 1")
    suspend fun getPinnedCount(): Int

    @Query("UPDATE clipboard_items SET is_pinned = :isPinned WHERE id = :id")
    suspend fun updatePinnedStatus(id: String, isPinned: Boolean)
    
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
