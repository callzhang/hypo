package com.hypo.clipboard.data.local

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.hypo.clipboard.domain.model.ClipboardType
import java.time.Instant

@Entity(
    tableName = "clipboard_items",
    indices = [
        Index(value = ["created_at"]),
        Index(value = ["device_id"]),
        Index(value = ["is_pinned"]),
        Index(value = ["type"]),
        Index(value = ["content"], unique = false) // For search optimization
    ]
)
data class ClipboardEntity(
    @PrimaryKey
    val id: String,
    @ColumnInfo(name = "type")
    val type: ClipboardType,
    @ColumnInfo(name = "content")
    val content: String,
    @ColumnInfo(name = "preview")
    val preview: String,
    @ColumnInfo(name = "metadata")
    val metadata: Map<String, String>?,
    @ColumnInfo(name = "device_id")
    val deviceId: String,
    @ColumnInfo(name = "device_name")
    val deviceName: String? = null,
    @ColumnInfo(name = "created_at")
    val createdAt: Instant,
    @ColumnInfo(name = "is_pinned")
    val isPinned: Boolean
)
