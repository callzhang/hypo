package com.hypo.clipboard.optimization

import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import android.content.Context
import com.hypo.clipboard.data.local.ClipboardDao
import com.hypo.clipboard.data.local.ClipboardEntity
import com.hypo.clipboard.data.local.Converters
import kotlinx.coroutines.CoroutineScope
import javax.inject.Singleton

@Database(
    entities = [ClipboardEntity::class],
    version = 2, // Incremented for optimizations
    exportSchema = true,
    autoMigrations = [
        // Add auto-migrations here if needed
    ]
)
@TypeConverters(Converters::class)
abstract class OptimizedHypoDatabase : RoomDatabase() {
    abstract fun clipboardDao(): OptimizedClipboardDao
    
    companion object {
        @Volatile
        private var INSTANCE: OptimizedHypoDatabase? = null
        
        fun getDatabase(
            context: Context,
            scope: CoroutineScope
        ): OptimizedHypoDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    OptimizedHypoDatabase::class.java,
                    "hypo_database"
                )
                .setJournalMode(RoomDatabase.JournalMode.WRITE_AHEAD_LOGGING)
                .setQueryExecutor(context.mainExecutor) // Use main executor for better performance
                .setTransactionExecutor(scope.coroutineContext.asExecutor())
                .addMigrations(MIGRATION_1_2)
                .addCallback(DatabaseCallback(scope))
                .build()
                INSTANCE = instance
                instance
            }
        }
        
        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(database: SupportSQLiteDatabase) {
                // Add FTS table for better search performance
                database.execSQL("""
                    CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts4(
                        content_id TEXT NOT NULL,
                        content TEXT NOT NULL,
                        preview TEXT NOT NULL
                    )
                """)
                
                // Create trigger to keep FTS table in sync
                database.execSQL("""
                    CREATE TRIGGER IF NOT EXISTS clipboard_fts_insert AFTER INSERT ON clipboard_items BEGIN
                        INSERT INTO clipboard_fts(content_id, content, preview) VALUES (NEW.id, NEW.content, NEW.preview);
                    END
                """)
                
                database.execSQL("""
                    CREATE TRIGGER IF NOT EXISTS clipboard_fts_delete AFTER DELETE ON clipboard_items BEGIN
                        DELETE FROM clipboard_fts WHERE content_id = OLD.id;
                    END
                """)
                
                database.execSQL("""
                    CREATE TRIGGER IF NOT EXISTS clipboard_fts_update AFTER UPDATE ON clipboard_items BEGIN
                        DELETE FROM clipboard_fts WHERE content_id = OLD.id;
                        INSERT INTO clipboard_fts(content_id, content, preview) VALUES (NEW.id, NEW.content, NEW.preview);
                    END
                """)
                
                // Populate FTS table with existing data
                database.execSQL("""
                    INSERT INTO clipboard_fts(content_id, content, preview)
                    SELECT id, content, preview FROM clipboard_items
                """)
            }
        }
        
        private class DatabaseCallback(
            private val scope: CoroutineScope
        ) : RoomDatabase.Callback() {
            override fun onCreate(db: SupportSQLiteDatabase) {
                super.onCreate(db)
                // Pre-populate with any default data if needed
            }
            
            override fun onOpen(db: SupportSQLiteDatabase) {
                super.onOpen(db)
                
                // Enable optimizations
                db.execSQL("PRAGMA synchronous = NORMAL")
                db.execSQL("PRAGMA cache_size = 2000") // 2MB cache
                db.execSQL("PRAGMA temp_store = MEMORY")
                db.execSQL("PRAGMA mmap_size = 268435456") // 256MB mmap
                
                // Enable foreign keys if needed
                // db.execSQL("PRAGMA foreign_keys = ON")
                
                // Create indexes for better performance if not auto-created
                db.execSQL("""
                    CREATE INDEX IF NOT EXISTS index_clipboard_items_created_at_pinned 
                    ON clipboard_items(is_pinned DESC, created_at DESC)
                """)
                
                db.execSQL("""
                    CREATE INDEX IF NOT EXISTS index_clipboard_items_device_created 
                    ON clipboard_items(device_id, created_at DESC)
                """)
                
                // Composite index for search operations
                db.execSQL("""
                    CREATE INDEX IF NOT EXISTS index_clipboard_items_type_created 
                    ON clipboard_items(type, created_at DESC)
                """)
            }
        }
    }
}