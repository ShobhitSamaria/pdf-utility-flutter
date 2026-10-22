package com.shobhit.pdfutility.pdf_utility_flutter

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateRemoteModel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val channelName = "pdf_utility/diagnostics"
    private val modelChannelName = "pdf_utility/model_manager"
    private val shareChannelName = "pdf_utility/share"
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceInfo" -> result.success(deviceInfo())
                    else -> result.notImplemented()
                }
            }

        // Our own model-management channel. The stock plugin
        // (GenericModelManager.kt) bridges the Play Services download Task
        // with only success/failure listeners and NO timeout: on some devices
        // the Task never calls back and the Dart future hangs forever. Every
        // method here logs BEFORE/AFTER under the shared tag and the download
        // path adds an explicit per-attempt watchdog so this channel ALWAYS
        // answers — success, failed or timeout — and the Dart side can retry
        // a stalled attempt with a fresh Task.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, modelChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isModelDownloaded" -> isModelDownloaded(call, result)
                    "downloadModel" -> downloadModel(call, result)
                    else -> result.notImplemented()
                }
            }

        // Sharing and exporting files. Android's share sheet is one intent, so
        // this needs no third-party plugin: the Dart side hands over a path and
        // gets back whether a chooser was actually shown. Three operations, one
        // channel:
        //   shareText      — plain text (OCR / translation results)
        //   shareFile      — a file in our cache, via a FileProvider content:// URI
        //   exportFile     — a copy the user can find later (Downloads)
        //   cacheDirectory — the app's own cache directory, where created PDFs
        //                    are written (see NativePdfOutputDirectory on the
        //                    Dart side)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareText" -> result.success(shareText(call))
                    "shareFile" -> result.success(shareFile(call))
                    "exportFile" -> result.success(exportFile(call))
                    "cacheDirectory" -> result.success(cacheDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Shows the system share sheet for the `text` argument.
     *
     * Returns `true` only when a chooser was launched. Blank text is rejected,
     * and a device with no app able to receive `text/plain` reports `false`
     * instead of crashing, so the Flutter side can tell the user rather than
     * showing a dead button.
     */
    private fun shareText(call: MethodCall): Boolean {
        val text = call.argument<String>("text")
        if (text.isNullOrBlank()) return false
        val subject = call.argument<String>("subject")

        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            if (subject != null) putExtra(Intent.EXTRA_SUBJECT, subject)
        }

        return try {
            startActivity(Intent.createChooser(send, subject))
            Log.i(OCR_TAG, "shareText: chooser shown (${text.length} chars)")
            true
        } catch (error: ActivityNotFoundException) {
            Log.e(OCR_TAG, "shareText: no ACTION_SEND handler on this device — $error")
            false
        } catch (error: Exception) {
            Log.e(OCR_TAG, "shareText: failed — $error")
            false
        }
    }

    /**
     * Shows the system share sheet for a file the app wrote (a created PDF).
     *
     * The file lives in the app's own cache, which no other app may read, so it
     * is handed over as a `content://` URI minted by our `FileProvider`
     * (see AndroidManifest.xml + res/xml/file_paths.xml) with a read grant that
     * lasts exactly as long as the receiving app needs it. Passing a `file://`
     * URI here would throw `FileUriExposedException` on Android 7+ and, before
     * that, silently leak the whole filesystem.
     *
     * Returns `true` only when a chooser was launched; a missing file, an
     * unshareable path (outside the provider's roots) or a device with no
     * `ACTION_SEND` target all report `false` so the Dart side can say so
     * instead of showing a dead button.
     */
    private fun shareFile(call: MethodCall): Boolean {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) return false
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        val subject = call.argument<String>("subject")
        val file = File(path)
        if (!file.exists() || !file.isFile) {
            Log.e(OCR_TAG, "shareFile: missing file $path")
            return false
        }

        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                if (subject != null) putExtra(Intent.EXTRA_SUBJECT, subject)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(send, subject))
            Log.i(OCR_TAG, "shareFile: chooser shown for ${file.name}")
            true
        } catch (error: IllegalArgumentException) {
            Log.e(OCR_TAG, "shareFile: $path is outside the FileProvider roots — $error")
            false
        } catch (error: ActivityNotFoundException) {
            Log.e(OCR_TAG, "shareFile: no ACTION_SEND handler on this device — $error")
            false
        } catch (error: Exception) {
            Log.e(OCR_TAG, "shareFile: failed — $error")
            false
        }
    }

    /**
     * Copies a file the app wrote somewhere the user can find it again, and
     * answers with a short human-readable location (`Downloads/Scan.pdf`), or
     * `null` when the copy could not be made — which the Dart side reports as a
     * failure rather than as success.
     *
     * Why MediaStore on Android 10+ rather than a plain file path: scoped
     * storage forbids writing to shared storage directly, and MediaStore is the
     * supported way to place a document in Downloads with the right MIME type so
     * Files, Drive and the system PDF viewer all pick it up. The `IS_PENDING`
     * dance keeps a half-written file invisible until it is complete. On older
     * releases (API < 29) there is no scoped storage to fight, so the app writes
     * into its own external files directory instead — the one location those
     * versions let an app write without a runtime permission.
     */
    private fun exportFile(call: MethodCall): String? {
        val path = call.argument<String>("path") ?: return null
        val requestedName = call.argument<String>("fileName") ?: File(path).name
        val mimeType = call.argument<String>("mimeType") ?: "application/pdf"
        // A name from the UI is untrusted here: strip anything that could escape
        // the destination folder and never allow an empty one.
        val safeName = requestedName
            .replace(Regex("[/\\\\\u0000-\u001f]"), "_")
            .trim()
            .ifBlank { "document.pdf" }
        val source = File(path)
        if (!source.exists() || !source.isFile) {
            Log.e(OCR_TAG, "exportFile: missing file $path")
            return null
        }

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS
                    )
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val collection =
                    MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val uri = contentResolver.insert(collection, values) ?: return null
                val copied = try {
                    contentResolver.openOutputStream(uri)?.use { output ->
                        source.inputStream().use { input -> input.copyTo(output) }
                        true
                    } ?: false
                } catch (error: Exception) {
                    // A failed copy must not leave a zero-byte entry behind.
                    contentResolver.delete(uri, null, null)
                    throw error
                }
                if (!copied) {
                    contentResolver.delete(uri, null, null)
                    return null
                }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                Log.i(OCR_TAG, "exportFile: wrote Downloads/$safeName")
                "Downloads/$safeName"
            } else {
                val directory = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                    ?: File(filesDir, "exports")
                directory.mkdirs()
                val target = File(directory, safeName)
                source.inputStream().use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
                Log.i(OCR_TAG, "exportFile: wrote ${target.absolutePath}")
                target.absolutePath
            }
        } catch (error: Exception) {
            Log.e(OCR_TAG, "exportFile: failed — $error")
            null
        }
    }

    /**
     * Bounded `isModelDownloaded` probe: normally answers in tens of
     * milliseconds; the Dart side bounds it too, so a wedged Task surfaces as
     * a timeout instead of a hang.
     */
    private fun isModelDownloaded(call: MethodCall, result: MethodChannel.Result) {
        val code = call.argument<String>("model")
        if (code == null) {
            result.error("bad_args", "missing model code", null)
            return
        }
        val started = SystemClock.elapsedRealtime()
        Log.i(TAG, "isModelDownloaded($code): BEFORE")
        try {
            RemoteModelManager.getInstance()
                .isModelDownloaded(TranslateRemoteModel.Builder(code).build())
                .addOnSuccessListener { downloaded ->
                    Log.i(
                        TAG,
                        "isModelDownloaded($code): AFTER OK → $downloaded " +
                            "(${SystemClock.elapsedRealtime() - started} ms)"
                    )
                    result.success(downloaded)
                }
                .addOnFailureListener { error ->
                    Log.e(
                        TAG,
                        "isModelDownloaded($code): AFTER FAILED " +
                            "(${SystemClock.elapsedRealtime() - started} ms) — $error"
                    )
                    result.error("check_failed", error.toString(), null)
                }
        } catch (error: Exception) {
            Log.e(TAG, "isModelDownloaded($code): AFTER FAILED — $error")
            result.error("check_failed", error.toString(), null)
        }
    }

    /**
     * ONE bounded download attempt for the model named by [call]s `model`
     * argument (BCP-47 code), answering with
     * `{status: success|failed|timeout, error, elapsedMs}`.
     *
     * Sequence: cheap `isModelDownloaded` pre-check (so a model that finished
     * in the background short-circuits) → `download` → listeners. A watchdog
     * posted for `timeoutMs` guarantees an answer even when the Play Services
     * Task never calls back — the exact stall observed as
     * `downloadModel(hi) never returned`. The `settled` flag makes sure
     * `MethodChannel.Result` is written exactly once even if the Task
     * completes after the watchdog fired.
     *
     * `wifi: false` (our Dart caller always sends it) builds plain
     * `DownloadConditions` — never `requireWifi()`, which would queue the
     * download until Wi-Fi and hang cellular-only phones on "Preparing …".
     */
    private fun downloadModel(call: MethodCall, result: MethodChannel.Result) {
        val code = call.argument<String>("model")
        if (code == null) {
            result.error("bad_args", "missing model code", null)
            return
        }
        val timeoutMs = (call.argument<Number>("timeoutMs") ?: 30_000).toLong()
        val wifi = call.argument<Boolean>("wifi") ?: false
        val model = TranslateRemoteModel.Builder(code).build()
        val conditions =
            if (wifi) {
                DownloadConditions.Builder().requireWifi().build()
            } else {
                DownloadConditions.Builder().build()
            }
        val started = SystemClock.elapsedRealtime()
        val settled = AtomicBoolean(false)

        Log.i(
            TAG,
            "downloadModel($code): BEFORE (deadline $timeoutMs ms, wifi=$wifi)"
        )

        // Runs on the main thread (listeners are added from it and the
        // watchdog posts to the main Handler); first writer wins.
        fun finish(status: String, detail: String?) {
            if (!settled.compareAndSet(false, true)) return
            val elapsed = SystemClock.elapsedRealtime() - started
            val suffix = if (detail == null) "" else " — $detail"
            Log.i(TAG, "downloadModel($code): $status after $elapsed ms$suffix")
            result.success(
                mapOf(
                    "status" to status,
                    "error" to detail,
                    "elapsedMs" to elapsed
                )
            )
        }

        val watchdog = Runnable {
            finish(
                "timeout",
                "the native download Task did not complete within $timeoutMs ms"
            )
        }
        mainHandler.postDelayed(watchdog, timeoutMs)

        try {
            val manager = RemoteModelManager.getInstance()
            manager.isModelDownloaded(model)
                .addOnSuccessListener { present ->
                    if (present) {
                        finish("success", "model already on device")
                        return@addOnSuccessListener
                    }
                    manager
                        .download(model, conditions)
                        .addOnSuccessListener { finish("success", null) }
                        .addOnFailureListener { error ->
                            finish("failed", error.toString())
                        }
                }
                .addOnFailureListener { error ->
                    finish("failed", "pre-check failed: $error")
                }
        } catch (error: Exception) {
            finish("failed", "could not start the download: $error")
        }
    }

    /**
     * Facts about this device that decide whether ML Kit model downloads can
     * work. Google Play Services is the download backend for ML Kit translation
     * models, so its presence/version is reported explicitly rather than assumed.
     *
     * No dependency is added for this: the Play Services version is simply the
     * version of its installed package.
     */
    @Suppress("DEPRECATION")
    private fun deviceInfo(): Map<String, Any?> {
        val info = mutableMapOf<String, Any?>(
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "androidRelease" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "supportedAbis" to Build.SUPPORTED_ABIS.joinToString(", "),
            "applicationId" to packageName
        )

        val gmsPackage = "com.google.android.gms"
        try {
            val packageInfo = packageManager.getPackageInfo(gmsPackage, 0)
            info["googlePlayServicesInstalled"] = true
            info["googlePlayServicesVersion"] = packageInfo.versionName
        } catch (e: Exception) {
            info["googlePlayServicesInstalled"] = false
            info["googlePlayServicesVersion"] =
                "not installed (${e.javaClass.simpleName})"
        }

        return info
    }

    companion object {
        /**
         * Shared with the Dart `translationLog` tag, so native and Dart lines
         * interleave in one grep: `adb logcat | grep PDF_UTILITY_TRANSLATION`.
         */
        private const val TAG = "PDF_UTILITY_TRANSLATION"

        /**
         * OCR-side native lines (sharing today, recognition instrumentation as
         * it lands). Filter with `adb logcat | grep PDF_UTILITY_OCR`.
         */
        private const val OCR_TAG = "PDF_UTILITY_OCR"
    }
}
