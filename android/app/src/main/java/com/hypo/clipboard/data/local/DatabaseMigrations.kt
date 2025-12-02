package com.hypo.clipboard.data.local

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * Room database migrations to handle schema changes without data loss.
 */
object DatabaseMigrations {
    /**
     * Migration from version 2 to 3:
     * - Adds `is_encrypted` column (Boolean, default false)
     * - Adds `transport_origin` column (String, nullable)
     */
    val MIGRATION_2_3 = object : Migration(2, 3) {
        override fun migrate(db: SupportSQLiteDatabase) {
            // Add is_encrypted column with default value false
            db.execSQL("ALTER TABLE clipboard_items ADD COLUMN is_encrypted INTEGER NOT NULL DEFAULT 0")
            
            // Add transport_origin column (nullable)
            db.execSQL("ALTER TABLE clipboard_items ADD COLUMN transport_origin TEXT")
        }
    }
}

