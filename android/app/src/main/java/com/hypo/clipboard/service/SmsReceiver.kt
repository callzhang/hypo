package com.hypo.clipboard.service

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/**
 * BroadcastReceiver that listens for incoming SMS messages, extracts OTP /
 * verification codes, and copies only the OTP to the clipboard so it can be
 * synced to peers via the existing clipboard sync mechanism.
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
            
            val otpCode = SmsOtpParser.extractOtp(fullMessage)
            if (otpCode == null) {
                Log.d(TAG, "⏭️ SMS from $senderNumber does not look like an OTP message")
                return
            }

            Log.d(
                TAG,
                "📱 Received OTP SMS from $senderNumber, extracted ${otpCode.length}-character code"
            )
            
            // Copy to clipboard
            val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newPlainText("SMS OTP", otpCode)
            clipboardManager.setPrimaryClip(clip)
            
            Log.d(TAG, "✅ OTP copied to clipboard for sync")
            
            // Note: The existing ClipboardListener will automatically detect this change
            // and sync it to peers via the existing clipboard sync mechanism
            
        } catch (e: SecurityException) {
            Log.w(TAG, "⚠️ SecurityException while processing SMS: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error processing SMS: ${e.message}", e)
        }
    }
}

