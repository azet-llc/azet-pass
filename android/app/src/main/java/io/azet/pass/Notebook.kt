package io.azet.pass

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.bitwarden.collections.CollectionView
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import kotlinx.coroutines.launch
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

data class NotebookEntry(val site: String, val username: String = "", val password: String = "", val url: String? = null, val extra: String = "", val include: Boolean = true)

/** How people write these pages: a site line, then "아이디/ID: …" and "비번/PW: …" lines, or all on one line
 *  ("네이버 kim1234 / abcd!234"). Labels in Korean, English and Japanese; known site names map to the preset address. */
object NotebookParser {
    private val idLabels = listOf("아이디", "아뒤", "id", "i.d", "user", "username", "login", "로그인", "이메일", "email", "메일", "ユーザー", "ログイン")
    private val pwLabels = listOf("비밀번호", "비번", "암호", "패스워드", "pw", "p/w", "pwd", "pass", "password", "パスワード")
    private val extraLabels = listOf("보안카드", "이체", "인증서", "공인인증", "핀", "pin", "질문", "답", "전화", "생일")
    private val mail = Regex("^([A-Za-z0-9._\\-]+?)[a©®&Q]?((naver|gmail|daum|hanmail|kakao|nate|icloud|outlook|hotmail|yahoo)\\.(com|net|co\\.kr))$")

    fun parse(raw: List<String>, loginWord: String = "Login"): List<NotebookEntry> {
        val out = mutableListOf<NotebookEntry>()
        var cur: NotebookEntry? = null
        fun flush() { cur?.let { if (it.username.isNotEmpty() || it.password.isNotEmpty()) out.add(it) }; cur = null }
        for (line in raw.map { it.trim() }.filter { it.isNotEmpty() }) {
            val lower = line.lowercase()
            val id = value(idLabels, line); val pw = if (id == null) value(pwLabels, line) else null
            when {
                id != null -> {
                    if (cur?.username?.isNotEmpty() == true) flush()
                    cur = (cur ?: NotebookEntry(loginWord)).copy(username = email(id))
                }
                pw != null -> cur = (cur ?: NotebookEntry(loginWord)).copy(password = pw)
                cur != null && extraLabels.any { lower.startsWith(it) } -> cur = cur!!.copy(extra = listOf(cur!!.extra, line).filter { it.isNotEmpty() }.joinToString("\n"))
                else -> {
                    val one = oneLine(line)
                    flush()
                    if (one != null) out.add(one)
                    else { // a heading: the next site
                        val p = Presets.match(line)
                        cur = NotebookEntry(p?.name ?: line.trim(' ', '-', '•', '·', '*', ':', '[', ']', '(', ')', '#'),
                            url = p?.url ?: line.takeIf { "." in it && " " !in it }?.let { if (it.startsWith("http")) it else "https://$it" })
                    }
                }
            }
        }
        flush()
        return out
    }

    /** "label : value", "label value", "label=value" */
    fun value(labels: List<String>, line: String): String? {
        val lower = line.lowercase()
        val l = labels.sortedByDescending { it.length }.firstOrNull { lower.startsWith(it) } ?: return null
        return line.drop(l.length).trim(' ', ':', '：', '=', '-', '—', '>', '）', ')', '\t').ifEmpty { null }
    }

    /** "네이버 kim1234 / abcd!234" or "naver: kim / pw" on one line. */
    fun oneLine(line: String): NotebookEntry? {
        val p = Presets.match(line) ?: return null
        val rest = line.replace(p.name, "").split('/', '|', ',', ' ', '\t').map { it.trim(':', '：') }.filter { it.isNotEmpty() }
        return if (rest.size >= 2) NotebookEntry(p.name, email(rest[0]), rest[1], p.url) else null
    }

    /** Handwritten "@" is often read as "a", "©" or "&": "soonjaanaver.com" → "soonja@naver.com" for the usual mail domains. */
    fun email(s: String): String {
        if ("@" in s) return s
        val m = mail.find(s) ?: return s
        return "${m.groupValues[1]}@${m.groupValues[2]}"
    }
}

/** Lines top to bottom, read on the phone (the Korean model, which also reads Latin letters, ships inside the app). */
suspend fun notebookLines(image: InputImage): List<String> = suspendCoroutine { k ->
    val rec = TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build())
    rec.process(image)
        .addOnSuccessListener { t -> k.resume(t.textBlocks.flatMap { it.lines }.sortedBy { it.boundingBox?.top ?: 0 }.map { it.text }); rec.close() }
        .addOnFailureListener { k.resume(emptyList()); rec.close() }
}

/** The camera with one shutter button. The picture stays in memory: it is read and dropped, never written to storage. */
@Composable
private fun PageCamera(onShot: (InputImage) -> Unit) {
    val ctx = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var allowed by remember { mutableStateOf(ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed = it }
    LaunchedEffect(Unit) { if (!allowed) ask.launch(Manifest.permission.CAMERA) }
    if (!allowed) { Box(Modifier.fillMaxSize().padding(28.dp)) { Text(stringResource(R.string.camera_needed), color = c().text) }; return }
    val capture = remember { ImageCapture.Builder().setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY).build() }
    Box(Modifier.fillMaxSize()) {
        AndroidView(modifier = Modifier.fillMaxSize(), factory = { c ->
            PreviewView(c).also { view ->
                val future = ProcessCameraProvider.getInstance(c)
                future.addListener({
                    val provider = future.get()
                    val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                    provider.unbindAll()
                    provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, capture)
                }, ContextCompat.getMainExecutor(c))
            }
        })
        val label = stringResource(R.string.scan_take)
        Box(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 28.dp).size(76.dp).clip(CircleShape).background(Color.White)
            .clickable(onClickLabel = label) {
                capture.takePicture(ContextCompat.getMainExecutor(ctx), object : ImageCapture.OnImageCapturedCallback() {
                    override fun onCaptureSuccess(image: ImageProxy) { val bmp = image.toBitmap(); val turn = image.imageInfo.rotationDegrees; image.close(); onShot(InputImage.fromBitmap(bmp, turn)) }
                    override fun onError(e: ImageCaptureException) {}
                })
            }, contentAlignment = Alignment.Center) { androidx.compose.material3.Icon(Icons.Filled.CameraAlt, label, tint = Color.Black) }
    }
}

/** Photo of a notebook page → logins, checked row by row before anything is saved. `vault` = the shared vault they go into. */
@Composable
fun ScanScreen(vault: CollectionView?, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var camera by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var rows by remember { mutableStateOf<List<NotebookEntry>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val loginWord = stringResource(R.string.scan_login_word)
    fun read(image: InputImage?) {
        camera = false; if (image == null) return
        busy = true
        scope.launch { rows = NotebookParser.parse(notebookLines(image), loginWord); busy = false }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> if (uri != null) read(runCatching { InputImage.fromFilePath(ctx, uri) }.getOrNull()) }
    if (camera) { BackHandler { camera = false }; PageCamera(::read); return }
    OnePage(vault?.name ?: stringResource(R.string.scan_title), onBack) {
        val list = rows
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            when {
                busy -> Box(Modifier.fillMaxWidth().padding(60.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = c().primary) }
                list == null -> {
                    Text(stringResource(R.string.scan_lead_title), Modifier.padding(horizontal = 26.dp, vertical = 8.dp), fontSize = 22.sp, fontWeight = FontWeight.Medium, color = c().text)
                    Text(stringResource(R.string.scan_lead), Modifier.padding(horizontal = 26.dp).padding(bottom = 20.dp), fontSize = 15.sp, lineHeight = 21.sp, color = c().sub)
                    OneCard {
                        OneRow(stringResource(R.string.scan_take), icon = Icons.Filled.CameraAlt, onClick = { camera = true })
                        OneDivider()
                        OneRow(stringResource(R.string.scan_pick), icon = Icons.Filled.Image, onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) })
                    }
                }
                list.isEmpty() -> {
                    Text(stringResource(R.string.scan_none), Modifier.padding(26.dp), fontSize = 16.sp, color = c().text)
                    TextButton({ rows = null }, Modifier.padding(horizontal = 14.dp)) { Text(stringResource(R.string.scan_other), color = c().primary, fontSize = 15.sp) }
                }
                else -> {
                    Text(stringResource(R.string.scan_check), Modifier.padding(horizontal = 26.dp).padding(bottom = 12.dp), fontSize = 15.sp, color = c().sub)
                    list.forEachIndexed { i, e ->
                        fun set(n: NotebookEntry) { rows = list.toMutableList().also { it[i] = n } }
                        OneCard(Modifier.padding(bottom = 12.dp)) {
                            Row(Modifier.padding(start = 8.dp, end = OneDim.rowPad), verticalAlignment = Alignment.CenterVertically) {
                                Box(Modifier.weight(1f)) { OneField(e.site, { set(e.copy(site = it)) }, stringResource(R.string.preset_site)) }
                                Spacer(Modifier.width(12.dp)); OneSwitch(e.include) { set(e.copy(include = it)) }
                            }
                            Column(Modifier.padding(horizontal = 8.dp).padding(bottom = 8.dp)) {
                                OneField(e.username, { set(e.copy(username = it)) }, stringResource(R.string.preset_user))
                                OneField(e.password, { set(e.copy(password = it)) }, stringResource(R.string.password))
                            }
                        }
                    }
                    error?.let { Text(it, Modifier.padding(horizontal = 26.dp), color = androidx.compose.material3.MaterialTheme.colorScheme.error, fontSize = 14.sp) }
                    TextButton({ rows = null }, Modifier.padding(horizontal = 14.dp)) { Text(stringResource(R.string.scan_other), color = c().primary, fontSize = 15.sp) }
                }
            }
        }
        val keep = list.orEmpty().filter { it.include }
        if (keep.isNotEmpty() && !busy) Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
            var saving by remember { mutableStateOf(false) }
            StepCta(stringResource(R.string.scan_save_n, keep.size), busy = saving, height = 56.dp) {
                saving = true; error = null
                scope.launch {
                    runCatching {
                        for (e in keep) Session.save(Session.newLogin(e.site, e.username, e.password, e.url)
                            .copy(notes = e.extra.ifEmpty { null }, organizationId = vault?.organizationId, collectionIds = listOfNotNull(vault?.id)))
                    }.onSuccess { onBack() }.onFailure { error = it.message }
                    saving = false
                }
            }
        }
    }
}
