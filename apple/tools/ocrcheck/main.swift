import Foundation
import Vision
import AppKit
enum Draft { static func normalizeURL(_ s: String) -> String { s.contains("://") ? s : "https://\(s)" } }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let img = NSImage(contentsOf: url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate; req.recognitionLanguages = ["ko-KR", "en-US"]; req.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: img).perform([req])
let lines = (req.results ?? []).sorted { $0.boundingBox.minY > $1.boundingBox.minY }.compactMap { $0.topCandidates(1).first?.string }
print("OCR:", lines)
for e in NotebookParser.parse(lines) { print("ENTRY", e.site, "|", e.username, "|", e.password, "|", e.url ?? "-", "|", e.extra) }
// the iOS engine reads a handwritten "@" as "a" at times (simulator run 10-27)
precondition(NotebookParser.email("soonjaanaver.com") == "soonja@naver.com")
precondition(NotebookParser.email("kim.s©gmail.com") == "kim.s@gmail.com")
precondition(NotebookParser.email("kimsoon52") == "kimsoon52" && NotebookParser.email("a@naver.com") == "a@naver.com")
