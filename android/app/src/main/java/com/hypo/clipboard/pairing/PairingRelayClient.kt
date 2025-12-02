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

    suspend fun createPairingCode(
        initiatorDeviceId: String,
        initiatorDeviceName: String,
        initiatorPublicKey: String
    ): PairingCode = withContext(Dispatchers.IO) {
        val requestBody = json.encodeToString(
            CreatePairingCodeRequest(
                initiatorDeviceId = initiatorDeviceId,
                initiatorDeviceName = initiatorDeviceName,
                initiatorPublicKey = initiatorPublicKey
            )
        ).toRequestBody(JSON)
        val request = Request.Builder()
            .url(baseUrl.newBuilder().addPathSegments("pairing/code").build())
            .post(requestBody)
            .header("Accept", "application/json")
            .build()
        execute(request) { response ->
            when (response.code) {
                200 -> json.decodeFromString<CreatePairingCodeResponse>(response.body!!.string()).toPairingCode()
                else -> throw relayError(response)
            }
        }
    }

    suspend fun claimPairingCode(
        code: String,
        responderDeviceId: String,
        responderDeviceName: String,
        responderPublicKey: String
    ): PairingClaim = withContext(Dispatchers.IO) {
        val requestBody = json.encodeToString(
            ClaimRequest(
                code = code,
                responderDeviceId = responderDeviceId,
                responderDeviceName = responderDeviceName,
                responderPublicKey = responderPublicKey
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

    suspend fun submitChallenge(code: String, responderDeviceId: String, challengeJson: String) {
        withContext(Dispatchers.IO) {
            val requestBody = json.encodeToString(
                ChallengeRequest(responderDeviceId = responderDeviceId, challenge = challengeJson)
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

    suspend fun pollChallenge(code: String, initiatorDeviceId: String): String = withContext(Dispatchers.IO) {
        val url = baseUrl.newBuilder()
            .addPathSegments("pairing/code/$code/challenge")
            .addQueryParameter("initiator_device_id", initiatorDeviceId)
            .build()
        val request = Request.Builder()
            .url(url)
            .get()
            .header("Accept", "application/json")
            .build()
        execute(request) { response ->
            when (response.code) {
                200 -> json.decodeFromString<ChallengeResponse>(response.body!!.string()).challenge
                404 -> {
                    val error = response.body?.string()
                    if (error?.contains("challenge not available", ignoreCase = true) == true) {
                        throw PairingRelayException.ChallengeNotReady
                    }
                    throw PairingRelayException.CodeNotFound
                }
                410 -> throw PairingRelayException.CodeExpired
                else -> throw relayError(response)
            }
        }
    }

    suspend fun submitAck(code: String, initiatorDeviceId: String, ackJson: String) {
        withContext(Dispatchers.IO) {
            val requestBody = json.encodeToString(
                SubmitAckRequest(initiatorDeviceId = initiatorDeviceId, ack = ackJson)
            ).toRequestBody(JSON)
            val request = Request.Builder()
                .url(baseUrl.newBuilder().addPathSegments("pairing/code/$code/ack").build())
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

    suspend fun pollAck(code: String, responderDeviceId: String): String = withContext(Dispatchers.IO) {
        val url = baseUrl.newBuilder()
            .addPathSegments("pairing/code/$code/ack")
            .addQueryParameter("responder_device_id", responderDeviceId)
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
private data class CreatePairingCodeRequest(
    @SerialName("initiator_device_id") val initiatorDeviceId: String,
    @SerialName("initiator_device_name") val initiatorDeviceName: String,
    @SerialName("initiator_public_key") val initiatorPublicKey: String
)

@Serializable
private data class CreatePairingCodeResponse(
    val code: String,
    @SerialName("expires_at") val expiresAt: String
) {
    fun toPairingCode(): PairingCode = PairingCode(
        code = code,
        expiresAt = Instant.parse(expiresAt)
    )
}

@Serializable
private data class ClaimRequest(
    val code: String,
    @SerialName("responder_device_id") val responderDeviceId: String,
    @SerialName("responder_device_name") val responderDeviceName: String,
    @SerialName("responder_public_key") val responderPublicKey: String
)

@Serializable
private data class ClaimResponse(
    @SerialName("initiator_device_id") val initiatorDeviceId: String,
    @SerialName("initiator_device_name") val initiatorDeviceName: String,
    @SerialName("initiator_public_key") val initiatorPublicKey: String,
    @SerialName("expires_at") val expiresAt: String
) {
    fun toClaim(): PairingClaim = PairingClaim(
        initiatorDeviceId = initiatorDeviceId,
        initiatorDeviceName = initiatorDeviceName,
        initiatorPublicKey = initiatorPublicKey,
        expiresAt = Instant.parse(expiresAt)
    )
}

@Serializable
private data class ChallengeRequest(
    @SerialName("responder_device_id") val responderDeviceId: String,
    val challenge: String
)

@Serializable
private data class ChallengeResponse(
    val challenge: String
)

@Serializable
private data class SubmitAckRequest(
    @SerialName("initiator_device_id") val initiatorDeviceId: String,
    val ack: String
)

@Serializable
private data class AckResponse(val ack: String)

@Serializable
private data class ErrorResponse(val error: String? = null)

data class PairingCode(
    val code: String,
    val expiresAt: Instant
)

data class PairingClaim(
    val initiatorDeviceId: String,
    val initiatorDeviceName: String,
    val initiatorPublicKey: String,
    val expiresAt: Instant
)

sealed class PairingRelayException(message: String? = null, cause: Throwable? = null) : Exception(message, cause) {
    data object CodeNotFound : PairingRelayException("Pairing code not found")
    data object CodeExpired : PairingRelayException("Pairing code expired")
    data object CodeAlreadyClaimed : PairingRelayException("Pairing code already claimed")
    data object AckNotReady : PairingRelayException("Acknowledgement not ready")
    data object ChallengeNotReady : PairingRelayException("Challenge not ready")
    data class Server(val errorMessage: String) : PairingRelayException(errorMessage)
    data class Network(val ioException: IOException) : PairingRelayException(ioException.message, ioException)
}
