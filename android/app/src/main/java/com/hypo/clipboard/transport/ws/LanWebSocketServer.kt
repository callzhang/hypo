package com.hypo.clipboard.transport.ws

import android.util.Log
import com.hypo.clipboard.pairing.PairingChallengeMessage
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import org.java_websocket.WebSocket
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.server.WebSocketServer

interface LanWebSocketServerDelegate {
    fun onPairingChallenge(server: LanWebSocketServer, challenge: PairingChallengeMessage, connectionId: String)
    fun onClipboardData(server: LanWebSocketServer, data: ByteArray, connectionId: String)
    fun onConnectionAccepted(server: LanWebSocketServer, connectionId: String)
    fun onConnectionClosed(server: LanWebSocketServer, connectionId: String)
}

/**
 * Lightweight WebSocket server for LAN clipboard sync.
 *
 * Previous versions hand-parsed frames and routinely dropped binary opcodes. This implementation
 * delegates framing/handshake/masking to the Java-WebSocket library, eliminating opcode parsing bugs.
 */
class LanWebSocketServer(
    port: Int,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
) {
    companion object {
        val json = Json { ignoreUnknownKeys = true }
        private const val TAG = "LanWebSocketServer"
    }

    private val server: WebSocketServer
    private val connectionIds = ConcurrentHashMap<WebSocket, String>()

    var delegate: LanWebSocketServerDelegate? = null

    init {
        server = object : WebSocketServer(InetSocketAddress(port)) {
            override fun onStart() {
                Log.d(TAG, "✅ WebSocket server started on port ${address.port}")
                // Align with previous timeout behaviour (~30s)
                connectionLostTimeout = 30
            }

            override fun onOpen(conn: WebSocket, handshake: ClientHandshake) {
                val id = UUID.randomUUID().toString()
                connectionIds[conn] = id
                Log.d(TAG, "🔔 Connection opened: $id from ${conn.remoteSocketAddress}")
                delegate?.onConnectionAccepted(this@LanWebSocketServer, id)
            }

            override fun onMessage(conn: WebSocket, message: String) {
                // Text messages are rare; forward as bytes to reuse same pipeline.
                // Note: Binary frames should route to onMessage(ByteBuffer), but if they
                // somehow come here, we'll handle them gracefully.
                Log.d(TAG, "✉️  Text message received (${message.length} chars) from ${connectionIds[conn]}")
                onMessage(conn, ByteBuffer.wrap(message.toByteArray()))
            }

            override fun onMessage(conn: WebSocket, bytes: ByteBuffer) {
                val id = connectionIds[conn] ?: return
                val payload = bytes.toByteArray()
                Log.d(TAG, "📥 Binary frame received: ${payload.size} bytes from $id")
                // Try to detect pairing challenge inline (mirrors prior behaviour)
                if (payload.size >= 4) {
                    val length = ((payload[0].toInt() and 0xFF) shl 24) or
                        ((payload[1].toInt() and 0xFF) shl 16) or
                        ((payload[2].toInt() and 0xFF) shl 8) or
                        (payload[3].toInt() and 0xFF)
                    if (payload.size >= 4 + length) {
                        runCatching {
                            val jsonBytes = payload.sliceArray(4 until 4 + length)
                            val message = String(jsonBytes, Charsets.UTF_8)
                            if (message.contains("\"initiator_device_id\"") && message.contains("\"initiator_pub_key\"")) {
                                val challenge = json.decodeFromString<PairingChallengeMessage>(message)
                                Log.d(TAG, "📋 Detected pairing challenge for $id")
                                delegate?.onPairingChallenge(this@LanWebSocketServer, challenge, id)
                                return
                            }
                        }.onFailure {
                            Log.w(TAG, "⚠️ Failed to decode potential pairing challenge: ${it.message}")
                        }
                    }
                }
                delegate?.onClipboardData(this@LanWebSocketServer, payload, id)
            }

            override fun onClose(conn: WebSocket, code: Int, reason: String, remote: Boolean) {
                val id = connectionIds.remove(conn)
                Log.d(TAG, "🔌 Connection closed: $id code=$code reason=$reason remote=$remote")
                if (id != null) {
                    delegate?.onConnectionClosed(this@LanWebSocketServer, id)
                }
            }

            override fun onError(conn: WebSocket?, ex: Exception) {
                val id = if (conn != null) connectionIds[conn] else "unknown"
                Log.e(TAG, "❌ WebSocket error for $id: ${ex.message}", ex)
            }
        }
    }

    fun start() {
        // Check if server is already running by checking if it has connections
        // Note: WebSocketServer doesn't expose isRunning, so we check connections
        try {
            if (server.connections.isNotEmpty()) {
                Log.w(TAG, "⚠️ Server already running")
                return
            }
        } catch (e: Exception) {
            // If server isn't started, connections access may throw, which is fine
        }
        Log.d(TAG, "🚀 Starting WebSocket server…")
        server.start()
    }

    fun stop() {
        Log.d(TAG, "🛑 Stopping WebSocket server…")
        try {
            server.stop(1000)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error stopping server: ${e.message}", e)
        } finally {
            connectionIds.clear()
        }
    }

    fun send(data: ByteArray, to: String): Boolean {
        val entry = connectionIds.entries.find { it.value == to } ?: return false.also {
            Log.w(TAG, "⚠️ Connection $to not found")
        }
        return runCatching {
            entry.key.send(data)
            true
        }.onFailure { Log.e(TAG, "❌ Failed to send to $to: ${it.message}", it) }
            .getOrDefault(false)
    }

    fun sendPairingAck(ackJson: String, to: String): Boolean =
        send(ackJson.toByteArray(Charsets.UTF_8), to)
}

private fun ByteBuffer.toByteArray(): ByteArray {
    val bytes = ByteArray(remaining())
    get(bytes)
    return bytes
}
