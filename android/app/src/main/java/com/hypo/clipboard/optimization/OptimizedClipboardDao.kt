package com.hypo.clipboard.optimization

import androidx.paging.PagingSource
import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.RawQuery
import androidx.room.Transaction
import androidx.sqlite.db.SupportSQLiteQuery
import kotlinx.coroutines.flow.Flow
import com.hypo.clipboard.data.local.ClipboardEntity
import com.hypo.clipboard.domain.model.ClipboardType
import java.time.Instant

@Dao
interface OptimizedClipboardDao {
    
    // Optimized queries with better indexing strategy
    
    @Query("""
        SELECT * FROM clipboard_items 
        ORDER BY is_pinned DESC, created_at DESC 
        LIMIT :limit
    """)
    fun observe(limit: Int = 200): Flow<List<ClipboardEntity>>

    @Query("""
        SELECT * FROM clipboard_items 
        ORDER BY is_pinned DESC, created_at DESC
    """)
    fun observePaged(): PagingSource<Int, ClipboardEntity>

    @Query("""
        SELECT * FROM clipboard_items 
        WHERE is_pinned = 1 
        ORDER BY created_at DESC
    """)
    fun observePinned(): Flow<List<ClipboardEntity>>

    // Use FTS for much better search performance
    @Query("""
        SELECT ci.* FROM clipboard_items ci
        INNER JOIN clipboard_fts fts ON ci.id = fts.content_id
        WHERE clipboard_fts MATCH :query
        ORDER BY ci.is_pinned DESC, ci.created_at DESC
        LIMIT :limit
    """)
    fun searchWithFts(query: String, limit: Int = 50): Flow<List<ClipboardEntity>>
    
    // Fallback search for devices without FTS support
    @Query("""
        SELECT * FROM clipboard_items 
        WHERE (content LIKE '%' || :query || '%' OR preview LIKE '%' || :query || '%')
        ORDER BY is_pinned DESC, created_at DESC 
        LIMIT :limit
    """)
    fun searchFallback(query: String, limit: Int = 50): Flow<List<ClipboardEntity>>

    @Query("""
        SELECT * FROM clipboard_items 
        WHERE device_id = :deviceId 
        ORDER BY created_at DESC 
        LIMIT :limit
    """)
    fun observeByDevice(deviceId: String, limit: Int = 100): Flow<List<ClipboardEntity>>

    @Query("""
        SELECT * FROM clipboard_items 
        WHERE type = :type 
        ORDER BY is_pinned DESC, created_at DESC 
        LIMIT :limit
    """)
    fun observeByType(type: ClipboardType, limit: Int = 100): Flow<List<ClipboardEntity>>

    // Batch operations for better performance
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

    // Optimized cleanup operations
    @Query("""
        DELETE FROM clipboard_items 
        WHERE created_at < :cutoff 
        AND is_pinned = 0
    """)
    suspend fun deleteOlderThan(cutoff: Instant)

    @Query("""
        DELETE FROM clipboard_items 
        WHERE id IN (
            SELECT id FROM clipboard_items 
            WHERE is_pinned = 0 
            ORDER BY created_at ASC 
            LIMIT (SELECT MAX(0, COUNT(*) - :keepCount) FROM clipboard_items WHERE is_pinned = 0)
        )
    """)
    suspend fun trimUnpinnedToSize(keepCount: Int)

    // More efficient single queries
    @Query("SELECT * FROM clipboard_items WHERE id = :id LIMIT 1")
    suspend fun findById(id: String): ClipboardEntity?

    @Query("SELECT COUNT(*) FROM clipboard_items")
    suspend fun getCount(): Int

    @Query("SELECT COUNT(*) FROM clipboard_items WHERE is_pinned = 1")
    suspend fun getPinnedCount(): Int

    @Query("""
        UPDATE clipboard_items 
        SET is_pinned = :isPinned 
        WHERE id = :id
    """)
    suspend fun updatePinnedStatus(id: String, isPinned: Boolean)

    // Bulk update operations for better performance
    @Query("""
        UPDATE clipboard_items 
        SET is_pinned = :isPinned 
        WHERE id IN (:ids)
    """)
    suspend fun updatePinnedStatusBulk(ids: List<String>, isPinned: Boolean)

    // Statistics queries for monitoring
    @Query("""
        SELECT 
            COUNT(*) as total,
            COUNT(CASE WHEN is_pinned = 1 THEN 1 END) as pinned,
            COUNT(CASE WHEN type = 'TEXT' THEN 1 END) as text_items,
            COUNT(CASE WHEN type = 'IMAGE' THEN 1 END) as image_items,
            COUNT(CASE WHEN type = 'FILE' THEN 1 END) as file_items,
            COUNT(CASE WHEN created_at >= :since THEN 1 END) as recent_items
        FROM clipboard_items
    """)
    suspend fun getStatistics(since: Instant): ClipboardStatistics

    // Memory optimization: get only essential data for lists
    @Query("""
        SELECT id, type, preview, device_id, created_at, is_pinned 
        FROM clipboard_items 
        ORDER BY is_pinned DESC, created_at DESC 
        LIMIT :limit
    """)
    fun observeLight(limit: Int = 200): Flow<List<ClipboardEntityLight>>

    // Advanced transaction operations
    @Transaction
    suspend fun replaceAll(entities: List<ClipboardEntity>) {
        clear()
        upsertAll(entities)
    }

    @Transaction
    suspend fun cleanupOldEntries(maxEntries: Int, maxAge: Instant): CleanupResult {
        val initialCount = getCount()
        
        // First, delete old entries
        deleteOlderThan(maxAge)
        val afterAgeCleanup = getCount()
        
        // Then, trim to size (keeping pinned items)
        trimUnpinnedToSize(maxEntries)
        val finalCount = getCount()
        
        return CleanupResult(
            initialCount = initialCount,
            deletedByAge = initialCount - afterAgeCleanup,
            deletedBySize = afterAgeCleanup - finalCount,
            finalCount = finalCount
        )
    }
    
    @Transaction 
    suspend fun optimizeDatabase() {
        // Run VACUUM and ANALYZE for database maintenance
        vacuumDatabase()
        analyzeDatabase()
    }
    
    @RawQuery
    suspend fun vacuumDatabase(query: SupportSQLiteQuery = SimpleSQLiteQuery("VACUUM"))
    
    @RawQuery 
    suspend fun analyzeDatabase(query: SupportSQLiteQuery = SimpleSQLiteQuery("ANALYZE"))
    
    // Raw query support for dynamic queries
    @RawQuery(observedEntities = [ClipboardEntity::class])
    fun observeWithRawQuery(query: SupportSQLiteQuery): Flow<List<ClipboardEntity>>
}

// Data classes for optimized operations
data class ClipboardStatistics(
    val total: Int,
    val pinned: Int,
    val textItems: Int,
    val imageItems: Int,
    val fileItems: Int,
    val recentItems: Int
)

data class ClipboardEntityLight(
    val id: String,
    val type: ClipboardType,
    val preview: String,
    val deviceId: String,
    val createdAt: Instant,
    val isPinned: Boolean
)

data class CleanupResult(
    val initialCount: Int,
    val deletedByAge: Int,
    val deletedBySize: Int,
    val finalCount: Int
) {
    val totalDeleted: Int get() = deletedByAge + deletedBySize
    val wasEffective: Boolean get() = totalDeleted > 0
}

// Simple SQLite query implementation
class SimpleSQLiteQuery(private val query: String) : SupportSQLiteQuery {
    override fun getSql(): String = query
    override fun getArgCount(): Int = 0
    override fun bindTo(statement: androidx.sqlite.db.SupportSQLiteProgram) = Unit
}