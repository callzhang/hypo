package com.hypo.clipboard.data.local

import androidx.room.TypeConverter
import com.hypo.clipboard.domain.model.ClipboardType
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant

class Converters {
    private val json = Json { ignoreUnknownKeys = true }

    @TypeConverter
    fun toInstant(epochMilli: Long?): Instant? = epochMilli?.let(Instant::ofEpochMilli)

    @TypeConverter
    fun fromInstant(instant: Instant?): Long? = instant?.toEpochMilli()

    @TypeConverter
    fun fromClipboardType(type: ClipboardType?): String? = type?.name

    @TypeConverter
    fun toClipboardType(raw: String?): ClipboardType? = raw?.let { ClipboardType.valueOf(it) }

    @TypeConverter
    fun fromMetadata(metadata: Map<String, String>?): String? = metadata?.let { json.encodeToString(it) }

    @TypeConverter
    fun toMetadata(jsonString: String?): Map<String, String>? = jsonString?.let {
        json.decodeFromString<Map<String, String>>(it)
    }
}
