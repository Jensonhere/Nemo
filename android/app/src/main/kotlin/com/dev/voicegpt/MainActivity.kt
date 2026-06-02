package com.dev.voicegpt

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.FlutterInjector
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.StandardMethodCodec

// MediaPipe 导入
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facedetector.FaceDetector
import com.google.mediapipe.tasks.vision.facedetector.FaceDetectorResult
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizerResult
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.components.containers.Detection
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage

// Android 导入
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.content.Context
import android.media.AudioManager
import android.os.Build
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.io.ByteArrayOutputStream
import java.util.HashMap
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.gesture_recognizer_app/mediapipe"
    private val EVENT_CHANNEL = "$CHANNEL/gestures"
    private val VOIP_AUDIO_CHANNEL = "com.dev.voicegpt/voip_audio"

    // 两种模式的手势识别器
    private var gestureRecognizer: GestureRecognizer? = null // live stream
    private var gestureRecognizerImageMode: GestureRecognizer? = null // image mode
    private var faceDetectorImageMode: FaceDetector? = null // image mode
    private var faceDetectorModelBuffer: ByteBuffer? = null

    private var eventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupFullscreen()
    }

    override fun onResume() {
        super.onResume()
        setupFullscreen()
    }

    private fun setupFullscreen() {
        // 设置全屏显示
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11 (API 30) 及以上版本
            WindowCompat.setDecorFitsSystemWindows(window, false)
            val windowInsetsController = WindowCompat.getInsetsController(window, window.decorView)
            windowInsetsController.hide(WindowInsetsCompat.Type.statusBars())
            windowInsetsController.hide(WindowInsetsCompat.Type.navigationBars())
            windowInsetsController.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        } else {
            // Android 10 及以下版本
            @Suppress("DEPRECATION")
            window.setFlags(
                WindowManager.LayoutParams.FLAG_FULLSCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN
            )
            
            // 隐藏导航栏
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOIP_AUDIO_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "setConversationVoipEnabled") {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val speaker = call.argument<Boolean>("speakerphone") ?: true
                    val tag = call.argument<String>("tag") ?: ""
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val prevMode = am.mode
                    @Suppress("DEPRECATION")
                    val prevSpeaker = am.isSpeakerphoneOn
                    Log.d(
                        "VoipAudioRoute",
                        "[$tag] setConversationVoipEnabled enabled=$enabled speaker=$speaker " +
                            "prevMode=$prevMode prevSpeaker=$prevSpeaker"
                    )
                    try {
                        if (enabled) {
                            am.mode = AudioManager.MODE_IN_COMMUNICATION
                            @Suppress("DEPRECATION")
                            run {
                                am.isSpeakerphoneOn = speaker
                            }
                            @Suppress("DEPRECATION")
                            val sp = am.isSpeakerphoneOn
                            Log.d(
                                "VoipAudioRoute",
                                "[$tag] applied MODE_IN_COMMUNICATION mode=${am.mode} speaker=$sp"
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            run {
                                am.isSpeakerphoneOn = false
                            }
                            am.mode = AudioManager.MODE_NORMAL
                            @Suppress("DEPRECATION")
                            val sp2 = am.isSpeakerphoneOn
                            Log.d(
                                "VoipAudioRoute",
                                "[$tag] applied MODE_NORMAL mode=${am.mode} speaker=$sp2"
                            )
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e("VoipAudioRoute", "[$tag] setConversationVoipEnabled failed", e)
                        result.error("VOIP_ROUTE", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "detectFaceInImage" -> {
                        val imagePath = call.argument<String>("path")
                        if (imagePath.isNullOrEmpty()) {
                            result.error("INVALID_ARGUMENTS", "Missing image path", null)
                            return@setMethodCallHandler
                        }

                        val bitmap = BitmapFactory.decodeFile(imagePath)
                        if (bitmap == null) {
                            result.error(
                                "IMAGE_DECODE_ERROR",
                                "Failed to decode image at path: $imagePath",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        try {
                            if (faceDetectorImageMode == null) {
                                initializeFaceDetectorImageMode()
                            }
                            val mpImage = BitmapImageBuilder(bitmap).build()
                            val detectResult = faceDetectorImageMode?.detect(mpImage)
                            result.success(
                                buildPrimaryFaceResultMap(
                                    detectResult = detectResult,
                                    imageWidth = bitmap.width.toFloat(),
                                    imageHeight = bitmap.height.toFloat()
                                )
                            )
                        } catch (e: Exception) {
                            result.error(
                                "FACE_DETECT_ERROR",
                                "Failed to detect face from image: ${e.message}",
                                null
                            )
                        }
                    }
                    // ----------- 单帧图片识别 -----------
                    "recognizeImage" -> {
                        val imagePath = call.argument<String>("path")
                        val imageBytes = call.argument<ByteArray>("bytes")
                        val width = call.argument<Int>("width")
                        val height = call.argument<Int>("height")
                        val format = call.argument<Int>("format")

                        var bitmap: Bitmap? = null
                        if (imagePath != null) {
                            bitmap = BitmapFactory.decodeFile(imagePath)
                            if (bitmap == null) {
                                result.error(
                                    "IMAGE_DECODE_ERROR",
                                    "Failed to decode image at path: $imagePath",
                                    null
                                )
                                return@setMethodCallHandler
                            }
                        } else if (imageBytes != null && width != null && height != null && format != null) {
                            if (format == ImageFormat.YUV_420_888) {
                                try {
                                    val yuvImage = YuvImage(
                                        imageBytes,
                                        ImageFormat.NV21,
                                        width,
                                        height,
                                        null
                                    )
                                    val out = ByteArrayOutputStream()
                                    yuvImage.compressToJpeg(Rect(0, 0, width, height), 90, out)
                                    val jpegBytes = out.toByteArray()
                                    bitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size)
                                } catch (e: Exception) {
                                    result.error(
                                        "IMAGE_DECODE_ERROR",
                                        "Failed to decode image from bytes: ${e.message}",
                                        null
                                    )
                                    return@setMethodCallHandler
                                }
                            } else {
                                result.error(
                                    "UNSUPPORTED_FORMAT",
                                    "Unsupported image format: $format",
                                    null
                                )
                                return@setMethodCallHandler
                            }
                        } else {
                            result.error(
                                "INVALID_ARGUMENTS",
                                "Missing image path or image bytes",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        try {
                            if (gestureRecognizerImageMode == null) {
                                initializeImageRecognizer()
                            }
                            val mpImage = BitmapImageBuilder(bitmap).build()
                            val resultBundle = gestureRecognizerImageMode?.recognize(mpImage)

                            val resultMap = HashMap<String, Any?>()
                            val gestures = resultBundle?.gestures()
                            if (gestures != null && gestures.isNotEmpty() && gestures[0].isNotEmpty()) {
                                val topGesture = gestures[0][0]
                                val recognizedGesture = topGesture.categoryName()
                                val score = topGesture.score()
                                resultMap["gesture"] = recognizedGesture
                                resultMap["score"] = score
                                try {
                                    val landmarks = resultBundle.landmarks()
                                    if (landmarks.isNotEmpty()) {
                                        val handLandmarksList = landmarks[0]
                                        if (handLandmarksList.isNotEmpty()) {
                                            var sumX = 0.0f
                                            var sumY = 0.0f
                                            for (landmark in handLandmarksList) {
                                                sumX += landmark.x()
                                                sumY += landmark.y()
                                            }
                                            val centerX = sumX / handLandmarksList.size
                                            val centerY = sumY / handLandmarksList.size
                                            resultMap["x"] = centerX.toDouble()
                                            resultMap["y"] = centerY.toDouble()
                                        }
                                    }
                                } catch (e: Exception) {
                                    // ignore
                                }
                            } else {
                                resultMap["gesture"] = "No gesture"
                            }
                            result.success(resultMap)
                        } catch (e: Exception) {
                            result.error(
                                "RECOGNIZE_IMAGE_ERROR",
                                "Failed to recognize gesture from image: ${e.message}",
                                null
                            )
                        }
                    }
                    // ----------- 实时流式识别 -----------
                    "processCameraImage" -> {
                        // 获取plane数据
                        val plane0 = call.argument<ByteArray>("plane0")
                        val plane1 = call.argument<ByteArray>("plane1")
                        val plane2 = call.argument<ByteArray>("plane2")
                        val width = call.argument<Int>("width") ?: 0
                        val height = call.argument<Int>("height") ?: 0
                        val pixelStride0 = call.argument<Int>("pixelStride0") ?: 1
                        val rowStride0 = call.argument<Int>("rowStride0") ?: 0
                        val pixelStride1 = call.argument<Int>("pixelStride1") ?: 1
                        val rowStride1 = call.argument<Int>("rowStride1") ?: 0
                        val pixelStride2 = call.argument<Int>("pixelStride2") ?: 1
                        val rowStride2 = call.argument<Int>("rowStride2") ?: 0

                        if (plane0 == null || plane1 == null || plane2 == null || width == 0 || height == 0) {
                            result.error("INVALID_ARGUMENTS", "Missing image planes or dimensions", null)
                            return@setMethodCallHandler
                        }

                        try {
                            val yuvPlanes = arrayOf(plane0, plane1, plane2)
                            val yuvPixelStrides = intArrayOf(pixelStride0, pixelStride1, pixelStride2)
                            val yuvRowStrides = intArrayOf(rowStride0, rowStride1, rowStride2)

                            // 高精度还原Bitmap
                            val bitmap = yuv420ToBitmap(yuvPlanes, yuvPixelStrides, yuvRowStrides, width, height)
                            processImageWithMediaPipe(bitmap)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("IMAGE_PROCESS_ERROR", "Failed to convert YUV image: ${e.message}", null)
                        }
                    }
                    "initializeRecognizer" -> {
                        initializeRecognizer()
                        initializeImageRecognizer() // 可选：初始化双模式
                        result.success(null)
                    }
                    "stopRecognizer" -> {
                        stopRecognizer()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL,
            StandardMethodCodec.INSTANCE
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    Log.d("MainActivity", "EventChannel onListen")
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    Log.d("MainActivity", "EventChannel onCancel")
                }
            }
        )
    }

    fun yuv420ToBitmap(
        yuvPlanes: Array<ByteArray>,
        pixelStrides: IntArray,
        rowStrides: IntArray,
        width: Int,
        height: Int
    ): Bitmap {
        val argb = IntArray(width * height)
        var yp = 0
        for (j in 0 until height) {
            val pY = rowStrides[0] * j
            val pU = rowStrides[1] * (j shr 1)
            val pV = rowStrides[2] * (j shr 1)
            for (i in 0 until width) {
                val y = 0xff and yuvPlanes[0][pY + i * pixelStrides[0]].toInt()
                val u = 0xff and yuvPlanes[1][pU + (i shr 1) * pixelStrides[1]].toInt()
                val v = 0xff and yuvPlanes[2][pV + (i shr 1) * pixelStrides[2]].toInt()
                // YUV to RGB conversion
                var yNew = y - 16
                var uNew = u - 128
                var vNew = v - 128
                if (yNew < 0) yNew = 0
                var r = (1.164f * yNew + 1.596f * vNew).toInt()
                var g = (1.164f * yNew - 0.813f * vNew - 0.391f * uNew).toInt()
                var b = (1.164f * yNew + 2.018f * uNew).toInt()
                r = r.coerceIn(0, 255)
                g = g.coerceIn(0, 255)
                b = b.coerceIn(0, 255)
                argb[yp++] = -0x1000000 or (r shl 16) or (g shl 8) or b
            }
        }
        return Bitmap.createBitmap(argb, width, height, Bitmap.Config.ARGB_8888)
    }

    // ------------- 初始化流模式 -------------
    private fun initializeRecognizer() {
        if (gestureRecognizer == null) {
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath("hand_gesture_recognizer.task")
                .build()
            val options = GestureRecognizer.GestureRecognizerOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.LIVE_STREAM)
                .setResultListener(this::onResults)
                .setErrorListener(this::onError)
                .build()
            try {
                gestureRecognizer = GestureRecognizer.createFromOptions(this, options)
                Log.d("MainActivity", "GestureRecognizer (LIVE_STREAM) initialized successfully.")
            } catch (e: Exception) {
                Log.e("MainActivity", "Error initializing GestureRecognizer (LIVE_STREAM): ${e.message}", e)
            }
        }
    }

    // ------------- 初始化单帧图片模式 -------------
    private fun initializeImageRecognizer() {
        if (gestureRecognizerImageMode == null) {
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath("hand_gesture_recognizer.task")
                .build()
            val options = GestureRecognizer.GestureRecognizerOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.IMAGE)
                .build()
            try {
                gestureRecognizerImageMode = GestureRecognizer.createFromOptions(this, options)
                Log.d("MainActivity", "GestureRecognizer (IMAGE) initialized successfully.")
            } catch (e: Exception) {
                Log.e("MainActivity", "Error initializing GestureRecognizer (IMAGE): ${e.message}", e)
            }
        }
    }

    private fun initializeFaceDetectorImageMode() {
        if (faceDetectorImageMode == null) {
            if (faceDetectorModelBuffer == null) {
                faceDetectorModelBuffer =
                    loadFlutterAssetModelBuffer("assets/models/face_detection_short_range.tflite")
            }
            val baseOptions = BaseOptions.builder()
                .setModelAssetBuffer(faceDetectorModelBuffer)
                .build()
            val options = FaceDetector.FaceDetectorOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.IMAGE)
                .build()
            try {
                faceDetectorImageMode = FaceDetector.createFromOptions(this, options)
                Log.d("MainActivity", "FaceDetector (IMAGE) initialized successfully.")
            } catch (e: Exception) {
                Log.e("MainActivity", "Error initializing FaceDetector (IMAGE): ${e.message}", e)
                throw e
            }
        }
    }

    private fun loadFlutterAssetModelBuffer(assetKey: String): ByteBuffer {
        val flutterAssetPath =
            FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(assetKey)
        assets.open(flutterAssetPath).use { input ->
            val bytes = input.readBytes()
            val buffer = ByteBuffer.allocateDirect(bytes.size)
            buffer.order(ByteOrder.nativeOrder())
            buffer.put(bytes)
            buffer.rewind()
            return buffer
        }
    }

    // -------- 流式处理回调，EventChannel 发送 --------
    private fun processImageWithMediaPipe(bitmap: Bitmap) {
        if (gestureRecognizer == null) {
            initializeRecognizer()
        }
        gestureRecognizer?.let {
            val mpImage = BitmapImageBuilder(bitmap).build()
            it.recognizeAsync(mpImage, System.currentTimeMillis())
        }
    }

    private fun onResults(
        resultBundle: GestureRecognizerResult,
        inputImage: MPImage
    ) {
        val resultMap = HashMap<String, Any?>()
        val gestures = resultBundle.gestures()
        if (gestures.isNotEmpty() && gestures[0].isNotEmpty()) {
            val topGesture = gestures[0][0]
            val recognizedGesture = topGesture.categoryName()
            val score = topGesture.score()

            resultMap["gesture"] = recognizedGesture
            resultMap["score"] = score

            try {
                val landmarks = resultBundle.landmarks()
                if (landmarks.isNotEmpty()) {
                    val handLandmarksList = landmarks[0]
                    if (handLandmarksList.isNotEmpty()) {
                        var sumX = 0.0f
                        var sumY = 0.0f
                        for (landmark in handLandmarksList) {
                            sumX += landmark.x()
                            sumY += landmark.y()
                        }
                        val centerX = sumX / handLandmarksList.size
                        val centerY = sumY / handLandmarksList.size
                        resultMap["x"] = centerX.toDouble()
                        resultMap["y"] = centerY.toDouble()
                    }
                }
            } catch (e: Exception) {
                // ignore
            }
        } else {
            resultMap["gesture"] = "No gesture"
        }

        Handler(Looper.getMainLooper()).post {
            eventSink?.success(resultMap)
        }
    }

    private fun onError(error: RuntimeException) {
        Log.e("MainActivity", "MediaPipe Error: ${error.message}", error)
        Handler(Looper.getMainLooper()).post {
            eventSink?.error("MEDIAPIPE_ERROR", error.message, null)
        }
    }

    private fun buildPrimaryFaceResultMap(
        detectResult: FaceDetectorResult?,
        imageWidth: Float,
        imageHeight: Float
    ): Map<String, Any?> {
        val detections = detectResult?.detections() ?: emptyList()
        if (detections.isEmpty()) {
            return hashMapOf("hasFace" to false)
        }

        val bestDetection = detections.maxByOrNull { detection ->
            val score = detection.categories().firstOrNull()?.score() ?: 0f
            val box = detection.boundingBox()
            score * box.width() * box.height()
        } ?: return hashMapOf("hasFace" to false)

        return detectionToFaceResultMap(bestDetection, imageWidth, imageHeight)
    }

    private fun detectionToFaceResultMap(
        detection: Detection,
        imageWidth: Float,
        imageHeight: Float
    ): Map<String, Any?> {
        val box = detection.boundingBox()
        val score = detection.categories().firstOrNull()?.score() ?: 0f

        val x = box.left.coerceAtLeast(0f)
        val y = box.top.coerceAtLeast(0f)
        val width = box.width().coerceAtLeast(0f)
        val height = box.height().coerceAtLeast(0f)
        val centerX = x + width / 2f
        val centerY = y + height / 2f

        return hashMapOf(
            "hasFace" to true,
            "centerX" to (centerX / imageWidth).toDouble(),
            "centerY" to (centerY / imageHeight).toDouble(),
            "bboxX" to (x / imageWidth).toDouble(),
            "bboxY" to (y / imageHeight).toDouble(),
            "bboxW" to (width / imageWidth).toDouble(),
            "bboxH" to (height / imageHeight).toDouble(),
            "confidence" to score.toDouble()
        )
    }

    private fun stopRecognizer() {
        gestureRecognizer?.close()
        gestureRecognizer = null
        gestureRecognizerImageMode?.close()
        gestureRecognizerImageMode = null
        faceDetectorImageMode?.close()
        faceDetectorImageMode = null
        faceDetectorModelBuffer = null
        Log.d("MainActivity", "GestureRecognizers stopped.")
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRecognizer()
    }
}
