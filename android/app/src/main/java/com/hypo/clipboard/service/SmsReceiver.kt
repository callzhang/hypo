package com.hypo.clipboard.service

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Telephony
import android.telephony.SmsMessage
import android.util.Log

/**
 * BroadcastReceiver that listens for incoming SMS messages and automatically
 * copies the SMS content to the clipboard, which will then be synced to macOS
 * via the existing clipboard sync mechanism.
 * 
 * Note: On Android 10+ (API 29+), SMS access is restricted. This receiver will
 * only work if the app is set as the default SMS app, or if the device is
 * running Android 9 or below.
 */
class SmsReceiver : BroadcastReceiver() {
    
    companion object {
        private const val TAG = "SmsReceiver"
    }
    
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
            return
        }
        
        try {
            // Extract SMS messages from intent
            val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            if (messages.isEmpty()) {
                Log.d(TAG, "📱 No SMS messages found in intent")
                return
            }
            
            // Combine all SMS parts into a single message body
            val messageBody = StringBuilder()
            var senderNumber: String? = null
            
            for (smsMessage in messages) {
                val body = smsMessage.messageBody
                if (body != null) {
                    messageBody.append(body)
                }
                // Get sender number from first message
                if (senderNumber == null) {
                    senderNumber = smsMessage.originatingAddress
                }
            }
            
            val fullMessage = messageBody.toString()
            if (fullMessage.isEmpty()) {
                Log.d(TAG, "📱 SMS message body is empty, skipping")
                return
            }
            
            // Format SMS content: include sender and message
            val formattedMessage = if (senderNumber != null) {
                "From: $senderNumber\n$fullMessage"
            } else {
                fullMessage
            }
            
            Log.d(TAG, "📱 Received SMS from $senderNumber: ${fullMessage.take(50)}...")
            
            // Copy to clipboard
            val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newPlainText("SMS", formattedMessage)
            clipboardManager.setPrimaryClip(clip)
            
            Log.d(TAG, "✅ SMS content copied to clipboard (${formattedMessage.length} chars)")
            
            // Note: The existing ClipboardListener will automatically detect this change
            // and sync it to macOS via the existing clipboard sync mechanism
            
        } catch (e: SecurityException) {
            // On Android 10+, SMS access may be restricted unless app is default SMS app
            Log.w(TAG, "⚠️ SecurityException: Cannot access SMS (may need to be default SMS app on Android 10+): ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error processing SMS: ${e.message}", e)
        }
    }
}

