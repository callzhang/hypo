package com.hypo.clipboard.util

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.util.Log
import java.lang.reflect.Method

/**
 * Utility class to attempt accessing MIUI's system clipboard history.
 * 
 * MIUI has a built-in clipboard history feature accessible from the IME (keyboard),
 * but there's no official public API to access it programmatically.
 * 
 * This class attempts various methods to access MIUI clipboard history:
 * 1. ContentProvider queries (if MIUI exposes clipboard history via ContentProvider)
 * 2. System service reflection (checking for MIUI-specific clipboard services)
 * 3. Database access (if clipboard history is stored in an accessible database)
 * 
 * Note: These methods may not work due to MIUI's privacy restrictions.
 */
object MiuiClipboardHistory {
    private const val TAG = "MiuiClipboardHistory"
    
    /**
     * Attempt to read MIUI clipboard history.
     * Returns a list of clipboard items if accessible, empty list otherwise.
     */
    fun tryReadClipboardHistory(context: Context): List<MiuiClipboardItem> {
        if (!MiuiAdapter.isMiuiOrHyperOS()) {
            Log.d(TAG, "Not a MIUI/HyperOS device, skipping clipboard history access")
            return emptyList()
        }
        
        Log.d(TAG, "Attempting to access MIUI clipboard history...")
        
        // Method 1: Try ContentProvider access
        val contentProviderItems = tryReadViaContentProvider(context)
        if (contentProviderItems.isNotEmpty()) {
            Log.i(TAG, "✅ Successfully read ${contentProviderItems.size} items via ContentProvider")
            return contentProviderItems
        }
        
        // Method 2: Try system service reflection
        val serviceItems = tryReadViaSystemService(context)
        if (serviceItems.isNotEmpty()) {
            Log.i(TAG, "✅ Successfully read ${serviceItems.size} items via System Service")
            return serviceItems
        }
        
        // Method 3: Try database access
        val dbItems = tryReadViaDatabase(context)
        if (dbItems.isNotEmpty()) {
            Log.i(TAG, "✅ Successfully read ${dbItems.size} items via Database")
            return dbItems
        }
        
        // Method 4: Try broadcast intents (discovery only, can't actually retrieve data)
        tryReadViaBroadcast(context)
        
        Log.w(TAG, "⚠️ Could not access MIUI clipboard history via any method")
        Log.d(TAG, "Note: MIUI clipboard history is not publicly accessible due to privacy restrictions.")
        Log.d(TAG, "This is expected behavior - MIUI does not expose clipboard history via public APIs.")
        return emptyList()
    }
    
    /**
     * Try accessing clipboard history via ContentProvider.
     * MIUI might expose clipboard history through a ContentProvider.
     */
    private fun tryReadViaContentProvider(context: Context): List<MiuiClipboardItem> {
        val items = mutableListOf<MiuiClipboardItem>()
        val contentResolver = context.contentResolver
        
        // Common MIUI clipboard ContentProvider URIs to try
        // Based on research: MIUI uses "Frequent Phrases" (com.miui.phrase) for clipboard management
        val possibleUris = listOf(
            "content://com.miui.contentextension/clipboard",
            "content://com.miui.contentextension/clipboard/history",
            "content://com.xiaomi.contentextension/clipboard",
            "content://com.xiaomi.contentextension/clipboard/history",
            "content://com.miui.clipboard/clipboard",
            "content://com.miui.clipboard/history",
            "content://com.miui.phrase/clipboard",  // MIUI "Frequent Phrases" app manages clipboard
            "content://com.miui.phrase/history",
            "content://com.miui.phrase/clipboard/history",
            "content://clipboard/clipboard",
            "content://clipboard/history",
        )
        
        for (uriString in possibleUris) {
            try {
                val uri = Uri.parse(uriString)
                val cursor: Cursor? = contentResolver.query(
                    uri,
                    null,
                    null,
                    null,
                    null
                )
                
                cursor?.use {
                    Log.d(TAG, "Found ContentProvider: $uriString, columns: ${it.columnNames?.joinToString()}")
                    
                    // Try to read data from cursor
                    val columnCount = it.columnCount
                    while (it.moveToNext()) {
                        val item = try {
                            // Try common column names
                            val text = it.getString(it.getColumnIndexOrThrow("text"))
                                ?: it.getString(it.getColumnIndexOrThrow("content"))
                                ?: it.getString(it.getColumnIndexOrThrow("data"))
                            
                            val timestamp = try {
                                it.getLong(it.getColumnIndexOrThrow("timestamp"))
                            } catch (e: Exception) {
                                try {
                                    it.getLong(it.getColumnIndexOrThrow("time"))
                                } catch (e2: Exception) {
                                    System.currentTimeMillis()
                                }
                            }
                            
                            MiuiClipboardItem(
                                text = text ?: "",
                                timestamp = timestamp
                            )
                        } catch (e: Exception) {
                            // Try to read all columns as strings
                            val columns = (0 until columnCount).map { colIndex ->
                                val columnName = it.getColumnName(colIndex)
                                val value = try {
                                    it.getString(colIndex) ?: ""
                                } catch (e: Exception) {
                                    ""
                                }
                                "$columnName=$value"
                            }
                            Log.d(TAG, "Row data: ${columns.joinToString(", ")}")
                            null
                        }
                        
                        if (item != null) {
                            items.add(item)
                        }
                    }
                }
            } catch (e: SecurityException) {
                Log.d(TAG, "ContentProvider access denied for $uriString: ${e.message}")
            } catch (e: Exception) {
                Log.d(TAG, "Failed to query ContentProvider $uriString: ${e.message}")
            }
        }
        
        return items
    }
    
    /**
     * Try accessing clipboard history via system service reflection.
     * MIUI might have a custom clipboard service.
     */
    private fun tryReadViaSystemService(context: Context): List<MiuiClipboardItem> {
        val items = mutableListOf<MiuiClipboardItem>()
        
        // Try to find MIUI clipboard service
        // Based on research: MIUI uses "Frequent Phrases" (com.miui.phrase) for clipboard management
        val possibleServiceNames = listOf(
            "clipboard",
            "miui.clipboard",
            "xiaomi.clipboard",
            "com.miui.clipboard",
            "com.xiaomi.clipboard",
            "com.miui.phrase",  // MIUI "Frequent Phrases" service
            "miui.phrase",
            "xiaomi.phrase"
        )
        
        for (serviceName in possibleServiceNames) {
            try {
                val service = context.getSystemService(serviceName)
                if (service != null) {
                    Log.d(TAG, "Found system service: $serviceName, class: ${service.javaClass.name}")
                    
                    // Try to call methods via reflection
                    val methods = service.javaClass.declaredMethods
                    for (method in methods) {
                        // Look for methods that might return clipboard history
                        if (method.name.contains("history", ignoreCase = true) ||
                            method.name.contains("list", ignoreCase = true) ||
                            method.name.contains("get", ignoreCase = true) ||
                            method.name.contains("clipboard", ignoreCase = true) ||
                            method.name.contains("phrase", ignoreCase = true) ||
                            method.name.contains("items", ignoreCase = true)) {
                            try {
                                method.isAccessible = true
                                
                                // Try calling with no parameters first
                                val result = try {
                                    method.invoke(service)
                                } catch (e: Exception) {
                                    // If no-arg fails, try with common parameters
                                    try {
                                        when (method.parameterCount) {
                                            1 -> {
                                                val paramType = method.parameterTypes[0]
                                                when {
                                                    paramType == Int::class.java -> method.invoke(service, 100) // limit
                                                    paramType == String::class.java -> method.invoke(service, "") // empty string
                                                    paramType == Long::class.java -> method.invoke(service, System.currentTimeMillis()) // timestamp
                                                    else -> null
                                                }
                                            }
                                            else -> null
                                        }
                                    } catch (e2: Exception) {
                                        null
                                    }
                                }
                                
                                if (result != null) {
                                    Log.d(TAG, "Method ${method.name} returned: $result (type: ${result.javaClass.name})")
                                    
                                    // Try to parse result
                                    when (result) {
                                        is List<*> -> {
                                            result.forEach { item ->
                                                Log.d(TAG, "Found list item: $item")
                                                // Try to extract text and timestamp from item
                                                if (item != null) {
                                                    try {
                                                        val itemClass = item.javaClass
                                                        var text: String? = null
                                                        
                                                        // Try to get text via method
                                                        try {
                                                            val getTextMethod = itemClass.getDeclaredMethod("getText")
                                                            if (getTextMethod.parameterCount == 0) {
                                                                getTextMethod.isAccessible = true
                                                                text = getTextMethod.invoke(item) as? String
                                                            }
                                                        } catch (e: Exception) {
                                                            // Try field access
                                                            try {
                                                                val textField = itemClass.getDeclaredField("text")
                                                                textField.isAccessible = true
                                                                text = textField.get(item) as? String
                                                            } catch (e2: Exception) {
                                                                try {
                                                                    val contentField = itemClass.getDeclaredField("content")
                                                                    contentField.isAccessible = true
                                                                    text = contentField.get(item) as? String
                                                                } catch (e3: Exception) {
                                                                    Log.d(TAG, "Could not extract text from item: ${e3.message}")
                                                                }
                                                            }
                                                        }
                                                        
                                                        if (text != null && text.isNotEmpty()) {
                                                            items.add(MiuiClipboardItem(text = text, timestamp = System.currentTimeMillis()))
                                                        }
                                                    } catch (e: Exception) {
                                                        Log.d(TAG, "Could not extract text from item: ${e.message}")
                                                    }
                                                }
                                            }
                                        }
                                        is Array<*> -> {
                                            result.forEach { item ->
                                                Log.d(TAG, "Found array item: $item")
                                            }
                                        }
                                        is String -> {
                                            Log.d(TAG, "Method returned string: $result")
                                        }
                                    }
                                }
                            } catch (e: Exception) {
                                Log.d(TAG, "Failed to invoke method ${method.name}: ${e.message}")
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.d(TAG, "Service $serviceName not available: ${e.message}")
            }
        }
        
        return items
    }
    
    /**
     * Try accessing clipboard history via database.
     * MIUI might store clipboard history in a database we can query.
     */
    private fun tryReadViaDatabase(context: Context): List<MiuiClipboardItem> {
        val items = mutableListOf<MiuiClipboardItem>()
        
        // Possible database paths for MIUI clipboard history
        // Based on research: MIUI uses "Frequent Phrases" (com.miui.phrase) for clipboard management
        val possibleDbPaths = listOf(
            "/data/data/com.miui.contentextension/databases/clipboard.db",
            "/data/data/com.xiaomi.contentextension/databases/clipboard.db",
            "/data/data/com.miui.clipboard/databases/clipboard.db",
            "/data/data/com.miui.phrase/databases/clipboard.db",  // MIUI "Frequent Phrases" database
            "/data/data/com.miui.phrase/databases/phrase.db",
            "/data/data/com.miui.phrase/databases/history.db",
            "/data/system/clipboard.db",
        )
        
        // Note: Direct database access requires root or the app to be the database owner
        // This is unlikely to work without root access
        for (dbPath in possibleDbPaths) {
            try {
                // This would require root access or the database to be accessible
                // For now, just log that we're checking
                Log.d(TAG, "Checking database path: $dbPath (requires root or app ownership)")
            } catch (e: Exception) {
                Log.d(TAG, "Cannot access database $dbPath: ${e.message}")
            }
        }
        
        return items
    }
    
    /**
     * Try accessing MIUI clipboard via BroadcastReceiver intents.
     * Some MIUI versions might expose clipboard history through broadcast intents.
     */
    private fun tryReadViaBroadcast(context: Context): List<MiuiClipboardItem> {
        val items = mutableListOf<MiuiClipboardItem>()
        
        // Try common clipboard-related broadcast intents
        val possibleIntents = listOf(
            "com.miui.clipboard.ACTION_GET_HISTORY",
            "com.xiaomi.clipboard.ACTION_GET_HISTORY",
            "com.miui.phrase.ACTION_GET_CLIPBOARD",
            "android.intent.action.CLIPBOARD_HISTORY",
        )
        
        for (action in possibleIntents) {
            try {
                val intent = android.content.Intent(action)
                val receivers = context.packageManager.queryBroadcastReceivers(intent, 0)
                Log.d(TAG, "Found ${receivers.size} receivers for intent: $action")
                
                // Note: We can't actually send broadcasts to get data back without a receiver
                // This is just for discovery
            } catch (e: Exception) {
                Log.d(TAG, "Failed to query broadcast receivers for $action: ${e.message}")
            }
        }
        
        return items
    }
    
    /**
     * Log all available ContentProviders on the device.
     * This can help discover if MIUI exposes clipboard history via ContentProvider.
     */
    fun logAvailableContentProviders(context: Context) {
        if (!MiuiAdapter.isMiuiOrHyperOS()) {
            return
        }
        
        Log.d(TAG, "Scanning for clipboard-related ContentProviders...")
        
        // Try to get list of all ContentProviders (requires reflection)
        try {
            val activityThread = Class.forName("android.app.ActivityThread")
            val currentApplication = activityThread.getMethod("currentApplication").invoke(null) as? Context
            val packageManager = currentApplication?.packageManager
            
            // This is complex and may not work, but worth trying
            Log.d(TAG, "ContentProvider discovery requires system-level access")
        } catch (e: Exception) {
            Log.d(TAG, "Failed to discover ContentProviders: ${e.message}")
        }
    }
}

/**
 * Data class representing a clipboard item from MIUI clipboard history.
 */
data class MiuiClipboardItem(
    val text: String,
    val timestamp: Long
)

