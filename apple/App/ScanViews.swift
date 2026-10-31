import AVFoundation
import BitwardenSdk
import PhotosUI
import SwiftUI
import Vision

/// "Parents' notebook" → items. Vision reads the page on this iPhone (no upload); the parser turns lines into
/// site / ID / password candidates and every candidate is shown for a check before anything is saved.
struct ScanNotebookView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var target: CollectionView?
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var image: UIImage?
    @State private var found: [NotebookEntry] = []
    @State private var reading = false
    @State private var saving = false
    @State private var saved = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if image == nil {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "book.closed.fill").font(.largeTitle).foregroundStyle(Theme.warm)
                            Text("Photograph one notebook page").font(.title3.bold())
                            Text("Lay the page flat in good light. Handwriting works. The photo is read on this iPhone and is not saved or sent anywhere.")
                                .foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                    Section {
                        #if os(iOS)
                        Button { camera = true } label: { Label("Take a photo", systemImage: "camera.fill") }
                        #endif
                        PhotosPicker(selection: $photo, matching: .images) { Label("Choose a photo", systemImage: "photo.on.rectangle") }
                    }
                } else if reading {
                    Section { HStack { ProgressView(); Text("Reading the page…") } }
                } else if saved > 0 {
                    Section {
                        Label("\(saved) items saved", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.brand)
                        Text("You can now tear out the page or keep the notebook somewhere safe. Logins fill themselves in from now on.")
                    }
                } else {
                    Section {
                        Text(found.isEmpty ? "No logins found on this page. Try a closer, brighter photo." : "Check each one. Fix anything misread, then save.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach($found) { $e in
                        Section {
                            Toggle(isOn: $e.include) { TextField("Site", text: $e.site).font(.headline) }
                            TextField("ID", text: $e.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Password", text: $e.password).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                            if let url = e.url { Text(url).font(.caption).foregroundStyle(.secondary) }
                            if !e.extra.isEmpty { Text(e.extra).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if !found.isEmpty {
                        Section {
                            Button { Task { await saveAll() } } label: {
                                HStack { Text("Save \(found.filter(\.include).count) items\(target.map { " → \($0.name)" } ?? "")"); if saving { Spacer(); ProgressView() } }
                            }.disabled(saving || !found.contains(where: \.include))
                        }
                    }
                }
            }
            .navigationTitle("Scan notebook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(saved > 0 ? "Done" : "Cancel") { dismiss() } }
                if image != nil, saved == 0 { ToolbarItem(placement: .primaryAction) { Button("Another photo") { image = nil; found = [] } } }
            }
            .onChange(of: photo) { _, p in Task { if let d = try? await p?.loadTransferable(type: Data.self), let i = UIImage(data: d) { await read(i) } } }
            #if os(iOS)
            .fullScreenCover(isPresented: $camera) { CameraPicker { img in camera = false; if let img { Task { await read(img) } } }.ignoresSafeArea() }
            #endif
            .errorAlert($error)
        }
    }

    private func read(_ img: UIImage) async {
        image = img; reading = true; defer { reading = false }
        let lines = await NotebookOCR.lines(img)
        found = NotebookParser.parse(lines)
    }

    private func saveAll() async {
        saving = true; defer { saving = false }
        var n = 0
        for e in found where e.include {
            var d = Draft(category: .login)
            d.name = e.site; d.username = e.username; d.password = e.password; d.urls = [e.url ?? ""]
            d.notes = e.extra
            if let t = target { d.familyId = t.organizationId; d.vaultIds = [t.id ?? ""] }
            do { try await session.save(d.view(), vaultIds: d.vaultIds); n += 1 } catch { self.error = error.localizedDescription; break }
        }
        saved = n
    }
}

struct NotebookEntry: Identifiable, Equatable {
    let id = UUID()
    var site: String
    var username = ""
    var password = ""
    var url: String?
    var extra = ""
    var include = true
}

enum NotebookOCR {
    /// Lines top to bottom, Korean and English handwriting and print, recognised on the device.
    static func lines(_ image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { r, _ in
                let obs = (r.results as? [VNRecognizedTextObservation]) ?? []
                let sorted = obs.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                cont.resume(returning: sorted.compactMap { $0.topCandidates(1).first?.string })
            }
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["ko-KR", "en-US", "ja-JP"]
            req.usesLanguageCorrection = false   // passwords are not words
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg, orientation: image.cgOrientation).perform([req]) } catch { cont.resume(returning: []) }
            }
        }
    }
}

#if os(iOS)
extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up; case .down: .down; case .left: .left; case .right: .right
        case .upMirrored: .upMirrored; case .downMirrored: .downMirrored; case .leftMirrored: .leftMirrored; case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
#endif

/// How people write these pages: a site line, then "아이디/ID: …" and "비번/PW: …" lines, or all on one line
/// ("네이버 kim1234 / abcd!234"). Labels in Korean, English and Japanese; known site names map to the preset URL.
enum NotebookParser {
    static let idLabels = ["아이디", "아뒤", "id", "i.d", "user", "username", "login", "로그인", "이메일", "email", "메일", "ユーザー", "ログイン"]
    static let pwLabels = ["비밀번호", "비번", "암호", "패스워드", "pw", "p/w", "pwd", "pass", "password", "パスワード"]
    static let extraLabels = ["보안카드", "이체", "인증서", "공인인증", "핀", "pin", "질문", "답", "전화", "생일"]

    static func parse(_ raw: [String]) -> [NotebookEntry] {
        var out: [NotebookEntry] = []
        var cur: NotebookEntry?
        func flush() { if let c = cur, !c.username.isEmpty || !c.password.isEmpty { out.append(c) }; cur = nil }
        for line in raw.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            let lower = line.lowercased()
            if let v = value(after: idLabels, in: line) {
                if cur == nil { cur = NotebookEntry(site: String(localized: "Login")) }
                if !(cur!.username.isEmpty) { flush(); cur = NotebookEntry(site: String(localized: "Login")) }
                cur!.username = email(v)
            } else if let v = value(after: pwLabels, in: line) {
                if cur == nil { cur = NotebookEntry(site: String(localized: "Login")) }
                cur!.password = v
            } else if extraLabels.contains(where: { lower.hasPrefix($0) }), cur != nil {
                cur!.extra += (cur!.extra.isEmpty ? "" : "\n") + line
            } else if let one = oneLine(line) {
                flush(); out.append(one)
            } else {
                // a heading: the next site
                flush()
                var e = NotebookEntry(site: line.trimmingCharacters(in: CharacterSet(charactersIn: "-•·*:[]()#").union(.whitespaces)))
                if let p = Preset.match(line) { e.site = p.name; e.url = p.url }
                else if line.contains("."), !line.contains(" ") { e.url = Draft.normalizeURL(line) }
                cur = e
            }
        }
        flush()
        return out
    }

    /// "label : value", "label value", "label=value"
    static func value(after labels: [String], in line: String) -> String? {
        let lower = line.lowercased()
        for l in labels.sorted(by: { $0.count > $1.count }) where lower.hasPrefix(l) {
            var rest = String(line.dropFirst(l.count))
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " :：=-—>）)").union(.whitespaces))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// "네이버 kim1234 / abcd!234" or "naver: kim / pw" on one line.
    static func oneLine(_ line: String) -> NotebookEntry? {
        guard let p = Preset.match(line) else { return nil }
        let rest = line.replacingOccurrences(of: p.name, with: "").components(separatedBy: CharacterSet(charactersIn: "/|,").union(.whitespaces))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":：")) }.filter { !$0.isEmpty }
        guard rest.count >= 2 else { return nil }
        return NotebookEntry(site: p.name, username: email(rest[0]), password: rest[1], url: p.url)
    }

    /// Handwritten "@" is often read as "a", "©" or "&": "soonjaanaver.com" → "soonja@naver.com" for the usual mail domains.
    static func email(_ s: String) -> String {
        guard !s.contains("@"), let m = s.firstMatch(of: #/^([A-Za-z0-9._\-]+?)[a©®&Q]?((naver|gmail|daum|hanmail|kakao|nate|icloud|outlook|hotmail|yahoo)\.(com|net|co\.kr))$/#) else { return s }
        return "\(m.1)@\(m.2)"
    }
}

#if os(iOS)
struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}

/// QR scanner for two-step login setup codes (otpauth://…).
struct QRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeUIViewController(context: Context) -> QRController { let c = QRController(); c.found = found; return c }
    func updateUIViewController(_ c: QRController, context: Context) {}

    final class QRController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        private let capture = AVCaptureSession()
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev), capture.canAddInput(input) else {
                let l = UILabel(); l.text = String(localized: "Camera not available. Paste the setup key instead."); l.textColor = .white; l.numberOfLines = 0
                l.frame = view.bounds.insetBy(dx: 24, dy: 200); view.addSubview(l); return
            }
            capture.addInput(input)
            let out = AVCaptureMetadataOutput()
            capture.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: capture)
            layer.frame = view.bounds; layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            DispatchQueue.global().async { self.capture.startRunning() }
        }
        func metadataOutput(_ o: AVCaptureMetadataOutput, didOutput objs: [AVMetadataObject], from c: AVCaptureConnection) {
            guard let s = (objs.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            capture.stopRunning(); found?(s)
        }
    }
}
#endif
