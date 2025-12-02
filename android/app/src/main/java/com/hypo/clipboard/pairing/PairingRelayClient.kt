package com.hypo.clipboard.pairing

import com.hypo.clipboard.BuildConfig
import java.io.IOException
import java.time.Instant
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

class PairingRelayClient @Inject constructor(
    private val client: OkHttpClient,
    private val json: Json = Json { ignoreUnknownKeys = true }
) {
    private val baseUrl: HttpUrl = BuildConfig.RELAY_WS_URL
        .replaceFirst("wss://", "https://")
        .replaceFirst("ws://", "http://")
        .removeSuffix("/ws")
        .let { url -> if (url.endsWith("/")) url else "$url/" }
        .toHttpUrl()

    suspend fun claimPairingCode(
        code: String,
        androidDeviceId: String,
        androidDeviceName: String,
        androidPublicKey: String
    ): PairingClaim = withContext(Dispatchers.IO) {
        val requestBody = json.encodeToString(
            ClaimRequest(
                code = code,
                androidDeviceId = androidDeviceId,
                androidDeviceName = androidDeviceName,
                androidPublicKey = androidPublicKey
            )
        ).toRequestBody(JSON)
        val request = Request.Builder()
            .url(baseUrl.newBuilder().addPathSegments("pairing/claim").build())
            .post(requestBody)
            .header("Accept", "application/json")
            .build()
        execute(request) { response ->
            when (response.code) {
                200 -> json.decodeFromString<ClaimResponse>(response.body!!.string()).toClaim()
                404 -> throw PairingRelayException.CodeNotFound
                409 -> throw PairingRelayException.CodeAlreadyClaimed
                410 -> throw PairingRelayException.CodeExpired
                else -> throw relayError(response)
            }
        }
    }

    suspend fun submitChallenge(code: String, androidDeviceId: String, challengeJson: String) {
        withContext(Dispatchers.IO) {
            val requestBody = json.encodeToString(
                ChallengeRequest(androidDeviceId = androidDeviceId, challenge = challengeJson)
            ).toRequestBody(JSON)
            val request = Request.Builder()
                .url(baseUrl.newBuilder().addPathSegments("pairing/code/$code/challenge").build())
                .post(requestBody)
                .header("Accept", "application/json")
                .build()
            execute(request) { response ->
                when (response.code) {
                    in 200..299 -> Unit
                    404 -> throw PairingRelayException.CodeNotFound
                    410 -> throw PairingRelayException.CodeExpired
                    else -> throw relayError(response)
                }
            }
        }
    }

    suspend fun pollAck(code: String, androidDeviceId: String): String = withContext(Dispatchers.IO) {
        val url = baseUrl.newBuilder()
            .addPathSegments("pairing/code/$code/ack")
            .addQueryParameter("android_device_id", androidDeviceId)
            .build()
        val request = Request.Builder()
            .url(url)
            .get()
            .header("Accept", "application/json")
            .build()
        execute(request) { response ->
            when (response.code) {
                200 -> json.decodeFromString<AckResponse>(response.body!!.string()).ack
                404 -> {
                    val error = response.body?.string()
                    if (error?.contains("acknowledgement not available", ignoreCase = true) == true) {
                        throw PairingRelayException.AckNotReady
                    }
                    throw PairingRelayException.CodeNotFound
                }
                410 -> throw PairingRelayException.CodeExpired
                else -> throw relayError(response)
            }
        }
    }

    private suspend fun <T> execute(request: Request, parser: (Response) -> T): T {
        val response = try {
            client.newCall(request).execute()
        } catch (error: IOException) {
            throw PairingRelayException.Network(error)
        }
        response.use { resp ->
            return parser(resp)
        }
    }

    private fun relayError(response: Response): PairingRelayException {
        val body = response.body?.string()
        val message = body?.let {
            runCatching { json.decodeFromString(ErrorResponse.serializer(), it).error }
                .getOrNull()
        }
        return PairingRelayException.Server(message ?: "Relay error (${response.code})")
    }

    companion object {
        private val JSON = "application/json".toMediaType()
    }
}

@Serializable
private data class ClaimRequest(
    val code: String,
    @SerialName("android_device_id") val androidDeviceId: String,
    @SerialName("android_device_name") val androidDeviceName: String,
    @SerialName("android_public_key") val androidPublicKey: String
)

@Serializable
private data class ClaimResponse(
    @SerialName("mac_device_id") val macDeviceId: String,
    @SerialName("mac_device_name") val macDeviceName: String,
    @SerialName("mac_public_key") val macPublicKey: String,
    @SerialName("expires_at") val expiresAt: String
) {
    fun toClaim(): PairingClaim = PairingClaim(
        macDeviceId = macDeviceId,
        macDeviceName = macDeviceName,
        macPublicKey = macPublicKey,
        expiresAt = Instant.parse(expiresAt)
    )
}

@Serializable
private data class ChallengeRequest(
    @SerialName("android_device_id") val androidDeviceId: String,
    val challenge: String
)

@Serializable
private data class AckResponse(val ack: String)

@Serializable
private data class ErrorResponse(val error: String? = null)

data class PairingClaim(
    val macDeviceId: String,
    val macDeviceName: String,
    val macPublicKey: String,
    val expiresAt: Instant
)

sealed class PairingRelayException(message: String? = null, cause: Throwable? = null) : Exception(message, cause) {
    data object CodeNotFound : PairingRelayException("Pairing code not found")
    data object CodeExpired : PairingRelayException("Pairing code expired")
    data object CodeAlreadyClaimed : PairingRelayException("Pairing code already claimed")
    data object AckNotReady : PairingRelayException("Acknowledgement not ready")
    data class Server(val errorMessage: String) : PairingRelayException(errorMessage)
    data class Network(val ioException: IOException) : PairingRelayException(ioException.message, ioException)
}
