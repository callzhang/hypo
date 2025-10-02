package com.hypo.clipboard.domain.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class ClipboardType {
    @SerialName("text")
    TEXT,
    @SerialName("link")
    LINK,
    @SerialName("image")
    IMAGE,
    @SerialName("file")
    FILE
}
