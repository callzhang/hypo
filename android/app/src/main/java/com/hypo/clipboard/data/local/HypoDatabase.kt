package com.hypo.clipboard.data.local

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.TypeConverters

@Database(
    entities = [ClipboardEntity::class],
    version = 1,
    exportSchema = true
)
@TypeConverters(Converters::class)
abstract class HypoDatabase : RoomDatabase() {
    abstract fun clipboardDao(): ClipboardDao
}
