package com.hypo.clipboard.service

import kotlin.math.max

/**
 * Extracts OTP / verification codes from SMS messages.
 *
 * The parser is intentionally conservative:
 * - It only returns a code when the message looks OTP-related.
 * - It supports both English and Chinese verification keywords.
 * - It prioritizes codes that appear near OTP keywords.
 */
object SmsOtpParser {

    private const val MIN_SMS_LIKE_TEXT_LENGTH = 20

    private val keywordPattern = Regex(
        pattern = listOf(
            "验证码",
            "校验码",
            "动态码",
            "动态密码",
            "安全码",
            "确认码",
            "认证码",
            "驗證碼",
            "驗證碼為",
            "驗證碼是",
            "code",
            "otp",
            "passcode",
            "verification code",
            "verify code",
            "security code",
            "auth code",
            "authorization code",
            "one-time password",
            "one time password",
            "activation code",
            "login code"
        ).joinToString(separator = "|") { Regex.escape(it) },
        option = RegexOption.IGNORE_CASE
    )

    private val directPatterns = listOf(
        Regex(
            "(?i)(?:验证码|校验码|动态码|动态密码|安全码|确认码|认证码|驗證碼|code|otp|passcode|verification code|verify code|security code|auth code|authorization code|one-time password|one time password|activation code|login code)[^A-Za-z0-9]{0,12}([A-Za-z0-9]{4,10})(?![A-Za-z0-9])"
        ),
        Regex(
            "(?i)(?<![A-Za-z0-9])([A-Za-z0-9]{4,10})[^A-Za-z0-9]{0,12}(?:为|是|碼為|碼是|验证码|校验码|动态码|动态密码|安全码|确认码|认证码|驗證碼|code|otp|passcode|verification code|verify code|security code|auth code|authorization code|one-time password|one time password|activation code|login code)"
        )
    )

    private val genericCandidatePattern = Regex("(?<![A-Za-z0-9])([A-Za-z0-9]{4,10})(?![A-Za-z0-9])")

    fun extractOtp(message: String): String? {
        val normalized = normalize(message)
        if (normalized.isBlank()) {
            return null
        }

        val keywordMatches = keywordPattern.findAll(normalized).toList()
        if (keywordMatches.isEmpty()) {
            return null
        }

        val candidates = linkedMapOf<String, Candidate>()

        directPatterns.forEachIndexed { index, regex ->
            regex.findAll(normalized).forEach { match ->
                val value = match.groupValues[1]
                if (isValidCandidate(value)) {
                    val start = match.groups[1]?.range?.first ?: match.range.first
                    val end = match.groups[1]?.range?.last?.plus(1) ?: match.range.last + 1
                    val score = scoreCandidate(
                        candidate = value,
                        start = start,
                        end = end,
                        message = normalized,
                        keywordMatches = keywordMatches,
                        directHitBonus = if (index == 0) 90 else 80
                    )
                    val existing = candidates[value]
                    if (existing == null || score > existing.score) {
                        candidates[value] = Candidate(value, start, end, score)
                    }
                }
            }
        }

        genericCandidatePattern.findAll(normalized).forEach { match ->
            val value = match.groupValues[1]
            if (isValidCandidate(value)) {
                val score = scoreCandidate(
                    candidate = value,
                    start = match.range.first,
                    end = match.range.last + 1,
                    message = normalized,
                    keywordMatches = keywordMatches,
                    directHitBonus = 0
                )
                val existing = candidates[value]
                if (existing == null || score > existing.score) {
                    candidates[value] = Candidate(value, match.range.first, match.range.last + 1, score)
                }
            }
        }

        return candidates.values
            .filter { it.score >= 70 }
            .maxWithOrNull(compareBy<Candidate> { it.score }.thenBy { -it.start })
            ?.value
    }

    fun extractOtpFromClipboardText(text: String): String? {
        val normalized = normalize(text)
        val otp = extractOtp(normalized) ?: return null
        if (!isLikelySmsLikeText(normalized)) {
            return null
        }
        return otp
    }

    private fun scoreCandidate(
        candidate: String,
        start: Int,
        end: Int,
        message: String,
        keywordMatches: List<MatchResult>,
        directHitBonus: Int
    ): Int {
        val nearestKeywordDistance = keywordMatches.minOf { keyword ->
            when {
                end <= keyword.range.first -> keyword.range.first - end
                start >= keyword.range.last + 1 -> start - (keyword.range.last + 1)
                else -> 0
            }
        }

        val windowStart = max(0, start - 24)
        val windowEnd = minOf(message.length, end + 24)
        val context = message.substring(windowStart, windowEnd).lowercase()

        var score = directHitBonus
        score += when {
            candidate.all(Char::isDigit) && candidate.length in 4..8 -> 55
            candidate.any(Char::isDigit) && candidate.any(Char::isLetter) && candidate.length in 4..10 -> 45
            candidate.all(Char::isDigit) -> 25
            else -> 5
        }

        score += when {
            nearestKeywordDistance == 0 -> 35
            nearestKeywordDistance <= 6 -> 30
            nearestKeywordDistance <= 16 -> 20
            nearestKeywordDistance <= 32 -> 10
            else -> 0
        }

        if (context.contains("minute") || context.contains("minutes") || context.contains("min") ||
            context.contains("有效") || context.contains("失效") || context.contains("expire") ||
            context.contains("expired") || context.contains("valid") || context.contains("use within")
        ) {
            score += 10
        }

        if (context.contains("不要") || context.contains("勿") || context.contains("do not share") || context.contains("never share")) {
            score += 5
        }

        return score
    }

    private fun isValidCandidate(candidate: String): Boolean {
        if (candidate.length !in 4..10) {
            return false
        }
        if (candidate.all(Char::isLetter)) {
            return false
        }
        if (candidate.matches(Regex("0{4,10}"))) {
            return false
        }
        if (candidate.matches(Regex("19\\d{2}|20\\d{2}"))) {
            return false
        }
        return true
    }

    private fun isLikelySmsLikeText(text: String): Boolean {
        if (text.length < MIN_SMS_LIKE_TEXT_LENGTH) {
            return false
        }

        val lowerText = text.lowercase()
        val hasOtpKeyword = keywordPattern.containsMatchIn(text)
        if (!hasOtpKeyword) {
            return false
        }

        val hasSentenceStructure = text.any {
            it in setOf('。', '，', '.', ',', '!', '！', ':', '：', '\n')
        }
        val hasValidityHint = listOf(
            "分钟", "分", "有效", "失效", "过期", "expire", "expired", "valid", "minute", "minutes"
        ).any { lowerText.contains(it) }
        val hasWarningHint = listOf(
            "勿泄露", "不要告诉", "切勿", "do not share", "never share"
        ).any { lowerText.contains(it) }
        val hasSenderFormatting = text.contains('【') || text.contains(']') || text.contains('[')

        return hasSentenceStructure || hasValidityHint || hasWarningHint || hasSenderFormatting
    }

    private fun normalize(message: String): String {
        return buildString(message.length) {
            message.forEach { char ->
                append(
                    when (char) {
                        in '０'..'９' -> '0' + (char - '０')
                        in 'Ａ'..'Ｚ' -> 'A' + (char - 'Ａ')
                        in 'ａ'..'ｚ' -> 'a' + (char - 'ａ')
                        '　' -> ' '
                        else -> char
                    }
                )
            }
        }
    }

    private data class Candidate(
        val value: String,
        val start: Int,
        val end: Int,
        val score: Int
    )
}
