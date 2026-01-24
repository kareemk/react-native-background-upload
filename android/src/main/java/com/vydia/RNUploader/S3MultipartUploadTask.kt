package com.vydia.RNUploader

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okio.BufferedSink
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream

data class CompletedPart(val partNumber: Int, val etag: String)

data class S3MultipartConfig(
    val uploadId: String,
    val objectKey: String,
    val presignedUrlEndpoint: String,
    val completeEndpoint: String,
    val clientId: String,
    val partSize: Int = 5 * 1024 * 1024, // 5MB default
    val headers: Map<String, String> = emptyMap()
)

interface S3MultipartUploadListener {
    fun onProgress(clientId: String, progress: Float)
    fun onPartCompleted(clientId: String, partNumber: Int, totalParts: Int, etag: String)
    fun onCompleted(clientId: String, objectKey: String)
    fun onError(clientId: String, error: String)
}

class S3MultipartUploadTask(
    private val context: Context,
    private val file: File,
    private val config: S3MultipartConfig,
    private val listener: S3MultipartUploadListener
) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(60, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(120, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(60, java.util.concurrent.TimeUnit.SECONDS)
        .build()
    
    private val completedParts = mutableListOf<CompletedPart>()
    private val totalParts: Int
    private var currentPart = 1
    private var isCancelled = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    private val prefs: SharedPreferences
        get() = context.getSharedPreferences("S3MultipartUpload", Context.MODE_PRIVATE)
    
    init {
        totalParts = ((file.length() + config.partSize - 1) / config.partSize).toInt()
        loadState()
    }
    
    fun start() {
        saveState()
        scope.launch { uploadNextPart() }
    }
    
    fun resume() {
        if (completedParts.size < totalParts) {
            currentPart = completedParts.size + 1
            scope.launch { uploadNextPart() }
        }
    }
    
    fun cancel() {
        isCancelled = true
        scope.cancel()
    }
    
    private suspend fun uploadNextPart() {
        if (isCancelled || currentPart > totalParts) return
        
        try {
            val startByte = (currentPart - 1).toLong() * config.partSize
            val endByte = minOf(startByte + config.partSize, file.length())
            val chunkSize = endByte - startByte
            
            // Get presigned URL
            val presignedUrl = fetchPresignedUrl(currentPart)
            
            // Create streaming request body
            val requestBody = object : RequestBody() {
                override fun contentType() = "application/octet-stream".toMediaType()
                override fun contentLength() = chunkSize
                
                override fun writeTo(sink: BufferedSink) {
                    FileInputStream(file).use { input ->
                        input.skip(startByte)
                        val buffer = ByteArray(8192)
                        var remaining = chunkSize
                        var bytesWritten = 0L
                        
                        while (remaining > 0) {
                            val toRead = minOf(buffer.size.toLong(), remaining).toInt()
                            val read = input.read(buffer, 0, toRead)
                            if (read == -1) break
                            
                            sink.write(buffer, 0, read)
                            remaining -= read
                            bytesWritten += read
                            
                            // Emit progress
                            val overallProgress = ((completedParts.size.toLong() * config.partSize + bytesWritten).toFloat() / file.length()) * 100
                            listener.onProgress(config.clientId, overallProgress)
                        }
                    }
                }
            }
            
            // Upload part
            val request = Request.Builder()
                .url(presignedUrl)
                .put(requestBody)
                .build()
            
            val response = client.newCall(request).execute()
            
            if (!response.isSuccessful) {
                throw Exception("Upload failed with status ${response.code}")
            }
            
            val etag = response.header("ETag")?.replace("\"", "") 
                ?: throw Exception("No ETag in response")
            
            completedParts.add(CompletedPart(currentPart, etag))
            saveState()
            
            listener.onPartCompleted(config.clientId, currentPart, totalParts, etag)
            
            if (currentPart < totalParts) {
                currentPart++
                uploadNextPart()
            } else {
                completeMultipartUpload()
            }
            
        } catch (e: Exception) {
            if (!isCancelled) {
                listener.onError(config.clientId, e.message ?: "Unknown error")
            }
        }
    }
    
    private suspend fun fetchPresignedUrl(partNumber: Int): String {
        val url = "${config.presignedUrlEndpoint}?partNumber=$partNumber&uploadId=${config.uploadId}&objectKey=${config.objectKey}"
        val requestBuilder = Request.Builder().url(url).get()
        config.headers.forEach { (key, value) -> requestBuilder.addHeader(key, value) }
        val response = client.newCall(requestBuilder.build()).execute()
        
        if (!response.isSuccessful) {
            throw Exception("Failed to get presigned URL: ${response.code}")
        }
        
        val json = JSONObject(response.body?.string() ?: "{}")
        return json.getString("url")
    }
    
    private suspend fun completeMultipartUpload() {
        val partsJson = JSONArray()
        completedParts.sortedBy { it.partNumber }.forEach { part ->
            partsJson.put(JSONObject().apply {
                put("partNumber", part.partNumber)
                put("etag", part.etag)
            })
        }
        
        val body = JSONObject().apply {
            put("uploadId", config.uploadId)
            put("objectKey", config.objectKey)
            put("clientId", config.clientId)
            put("parts", partsJson)
        }.toString()
        
        val requestBuilder = Request.Builder()
            .url(config.completeEndpoint)
            .post(RequestBody.create("application/json".toMediaType(), body))
        config.headers.forEach { (key, value) -> requestBuilder.addHeader(key, value) }
        
        val response = client.newCall(requestBuilder.build()).execute()
        
        if (!response.isSuccessful) {
            throw Exception("Complete upload failed: ${response.code}")
        }
        
        clearState()
        listener.onCompleted(config.clientId, config.objectKey)
    }
    
    private fun saveState() {
        val json = JSONObject().apply {
            put("uploadId", config.uploadId)
            put("objectKey", config.objectKey)
            put("presignedUrlEndpoint", config.presignedUrlEndpoint)
            put("completeEndpoint", config.completeEndpoint)
            put("partSize", config.partSize)
            put("totalParts", totalParts)
            put("filePath", file.absolutePath)
            put("completedParts", JSONArray().apply {
                completedParts.forEach { part ->
                    put(JSONObject().apply {
                        put("partNumber", part.partNumber)
                        put("etag", part.etag)
                    })
                }
            })
        }
        prefs.edit().putString(config.clientId, json.toString()).apply()
    }
    
    private fun loadState() {
        val json = prefs.getString(config.clientId, null) ?: return
        try {
            val obj = JSONObject(json)
            // Only restore state if uploadId matches - otherwise this is a new upload
            val savedUploadId = obj.optString("uploadId", "")
            if (savedUploadId != config.uploadId) {
                // Different uploadId means server reset the upload - start fresh
                clearState()
                return
            }
            val parts = obj.getJSONArray("completedParts")
            for (i in 0 until parts.length()) {
                val part = parts.getJSONObject(i)
                completedParts.add(CompletedPart(part.getInt("partNumber"), part.getString("etag")))
            }
            currentPart = completedParts.size + 1
        } catch (e: Exception) {
            // Ignore parse errors, start fresh
        }
    }
    
    private fun clearState() {
        prefs.edit().remove(config.clientId).apply()
    }
    
    companion object {
        fun getUploadStatus(context: Context, clientId: String): Map<String, Any>? {
            val prefs = context.getSharedPreferences("S3MultipartUpload", Context.MODE_PRIVATE)
            val json = prefs.getString(clientId, null) ?: return null
            
            return try {
                val obj = JSONObject(json)
                val parts = mutableListOf<Map<String, Any>>()
                val partsJson = obj.getJSONArray("completedParts")
                for (i in 0 until partsJson.length()) {
                    val part = partsJson.getJSONObject(i)
                    parts.add(mapOf("partNumber" to part.getInt("partNumber"), "etag" to part.getString("etag")))
                }
                
                mapOf(
                    "clientId" to clientId,
                    "uploadId" to obj.getString("uploadId"),
                    "objectKey" to obj.getString("objectKey"),
                    "completedParts" to parts,
                    "totalParts" to obj.getInt("totalParts"),
                    "inProgress" to false
                )
            } catch (e: Exception) {
                null
            }
        }
        
        fun clearUploadState(context: Context, clientId: String) {
            val prefs = context.getSharedPreferences("S3MultipartUpload", Context.MODE_PRIVATE)
            prefs.edit().remove(clientId).apply()
        }
    }
}
