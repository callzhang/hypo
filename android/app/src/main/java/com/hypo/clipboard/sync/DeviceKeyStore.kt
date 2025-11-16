package com.hypo.clipboard.sync

interface DeviceKeyStore {
    suspend fun saveKey(deviceId: String, key: ByteArray)
    suspend fun loadKey(deviceId: String): ByteArray?
    suspend fun deleteKey(deviceId: String)
    suspend fun getAllDeviceIds(): List<String>
}
