package com.hypo.clipboard.data.local

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface ClipboardDao {
    @Query("SELECT * FROM clipboard_items ORDER BY created_at DESC LIMIT :limit")
    fun observe(limit: Int = 200): Flow<List<ClipboardEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: ClipboardEntity)

    @Delete
    suspend fun delete(entity: ClipboardEntity)

    @Query("DELETE FROM clipboard_items WHERE id = :id")
    suspend fun deleteById(id: String)

    @Query("DELETE FROM clipboard_items")
    suspend fun clear()

    @Query("SELECT * FROM clipboard_items WHERE id = :id LIMIT 1")
    suspend fun findById(id: String): ClipboardEntity?
}
