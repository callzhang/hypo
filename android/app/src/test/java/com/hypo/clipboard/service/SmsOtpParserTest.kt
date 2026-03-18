package com.hypo.clipboard.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SmsOtpParserTest {

    @Test
    fun extractsEnglishNumericVerificationCode() {
        val message = "Your Example verification code is 123456. It expires in 10 minutes."

        assertEquals("123456", SmsOtpParser.extractOtp(message))
    }

    @Test
    fun extractsChineseVerificationCode() {
        val message = "【Hypo】您的验证码为 654321，5分钟内有效，请勿泄露给他人。"

        assertEquals("654321", SmsOtpParser.extractOtp(message))
    }

    @Test
    fun extractsMixedAlphaNumericOtp() {
        val message = "Use OTP: AB12CD to finish sign in. Do not share this code."

        assertEquals("AB12CD", SmsOtpParser.extractOtp(message))
    }

    @Test
    fun normalizesFullWidthDigitsBeforeParsing() {
        val message = "验证码：１２３４５６，请在5分钟内完成验证。"

        assertEquals("123456", SmsOtpParser.extractOtp(message))
    }

    @Test
    fun ignoresMessagesWithoutOtpKeywords() {
        val message = "Your package 123456 has been shipped and arrives tomorrow."

        assertNull(SmsOtpParser.extractOtp(message))
    }

    @Test
    fun prefersCodeNearKeywordOverOtherNumbers() {
        val message = "Order 998877 is confirmed. Your login code is 432198 and is valid for 5 min."

        assertEquals("432198", SmsOtpParser.extractOtp(message))
    }

    @Test
    fun extractsOtpFromClipboardWhenTextLooksLikeSms() {
        val message = "[Bank] Your verification code is 246810. It expires in 5 minutes. Do not share it."

        assertEquals("246810", SmsOtpParser.extractOtpFromClipboardText(message))
    }

    @Test
    fun doesNotCollapseShortNonSmsClipboardText() {
        val message = "code 123456"

        assertNull(SmsOtpParser.extractOtpFromClipboardText(message))
    }
}
