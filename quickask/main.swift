// Quick Ask: SamSearch's helper.
//
// A local server on 127.0.0.1:47213 whose pages SamSearch shows inside its panel:
//   /ask?q=…      Haiku (through CLIProxyAPI) answers with what you're looking at: a screenshot of the
//                 window behind the launcher plus its text (the open browser tab, or OCR).
//   /digup?q=…    DigUp's results for your files, screenshots, email and Drive.
//   /codes        Recent verification codes from both inboxes and Messages.
// And quickask:// links, for rows that hand off rather than show a page:
//   quickask://t3-thread-create?q=…   a new T3 Code thread with default settings, then jump to it
//   quickask://answer?q=…             the same answer page in a floating window
import Cocoa
import Network
import QuickLookThumbnailing
import Vision
import WebKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let PORT: UInt16 = ProcessInfo.processInfo.environment["QUICKASK_PORT"].flatMap(UInt16.init).flatMap { $0 > 0 ? $0 : nil } ?? 47213
let T3 = home + "/.t3/bin/t3"
let PROJECT = home + "/SaminOS"
let MODEL = "claude-haiku-5-5"
let PROXY = "http://127.0.0.1:8317"
let DIGUP = "/Applications/DigUp.app/Contents/Helpers/digup"
let GH = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "gh"
let GITHUB_OWNERS = ["Samin12", "AI-Answer", "creatorauthority"]
let HANDOFF = "@@T3"
let SHOTS = home + "/Library/Caches/samin-quick-ask"
let LOG = home + "/Library/Logs/QuickAsk.log"

func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: LOG) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        FileManager.default.createFile(atPath: LOG, contents: line.data(using: .utf8))
    }
}

func apiKey() -> String {
    guard let text = try? String(contentsOfFile: home + "/.cli-proxy-api/keys.env", encoding: .utf8) else { return "" }
    for line in text.split(separator: "\n") where line.hasPrefix("CPA_API_KEY=") {
        return String(line.dropFirst("CPA_API_KEY=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
    return ""
}

@discardableResult
func run(_ cmd: String, _ args: [String], input: String? = nil, cwd: String? = nil) -> (code: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out; p.standardError = err; p.standardInput = inp
    do { try p.run() } catch { return (-1, "", error.localizedDescription) }
    if let input { inp.fileHandleForWriting.write(input.data(using: .utf8)!) }
    try? inp.fileHandleForWriting.close()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

func jsonData(_ v: Any) -> Data { (try? JSONSerialization.data(withJSONObject: v)) ?? Data("{}".utf8) }

/// A `q=` value as Nanolight/SamSearch send it: spaces as "+", the rest percent-encoded.
func formValue(_ raw: String) -> String {
    (raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
}

func queryItems(_ query: Substring?) -> [String: String] {
    var out: [String: String] = [:]
    for pair in (query ?? "").split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        out[String(kv[0])] = kv.count > 1 ? formValue(String(kv[1])) : ""
    }
    return out
}

// MARK: - What's on screen

struct Screen {
    let path: String
    let app: String
    let title: String
    var url: String? = nil
    var text: String? = nil      // the page or window as text
    var textSource = ""          // "page" (read from the browser tab) or "ocr" (read off the screenshot)

    var how: String { textSource == "page" ? "reading the page" : textSource == "ocr" ? "reading the screen" : "" }
}

// Front window that isn't the launcher or this helper.
let FRONT_WINDOW_JXA = """
ObjC.import('CoreGraphics');
function run() {
  const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, $.kCGNullWindowID)));
  const skip = /^(SamSearch|Nanolight|nanolight|Quick Ask|QuickAsk|Window Server|Dock|Control Center|SystemUIServer|Notification Center|Spotlight)$/;
  for (const w of list) {
    const b = w.kCGWindowBounds || {};
    if (w.kCGWindowLayer !== 0 || skip.test(w.kCGWindowOwnerName || '') || (b.Width || 0) < 200 || (b.Height || 0) < 150) continue;
    return JSON.stringify({ id: w.kCGWindowNumber, app: w.kCGWindowOwnerName || '', title: w.kCGWindowName || '' });
  }
  return '';
}
"""

func captureScreen() -> Screen? {
    try? FileManager.default.createDirectory(atPath: SHOTS, withIntermediateDirectories: true)
    let path = "\(SHOTS)/screen-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
    var id: Int?, app = "Screen", title = ""
    let r = run("/usr/bin/osascript", ["-l", "JavaScript", "-e", FRONT_WINDOW_JXA])
    if let d = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        id = j["id"] as? Int; app = j["app"] as? String ?? app; title = j["title"] as? String ?? ""
    }
    run("/usr/sbin/screencapture", ["-x", "-t", "jpg"] + (id.map { ["-o", "-l\($0)"] } ?? ["-m"]) + [path])
    guard FileManager.default.fileExists(atPath: path) else {
        log("screenshot failed (Screen Recording permission?)")
        return nil
    }
    // Retina captures are huge; 1600px is plenty for the model and keeps it fast.
    run("/usr/bin/sips", ["-Z", "1600", path])
    var screen = Screen(path: path, app: app, title: title)
    addText(to: &screen)
    return screen
}

let CHROMIUM = ["Google Chrome", "Google Chrome Canary", "Arc", "Brave Browser", "Microsoft Edge", "BrowserOS", "Comet", "Chromium", "Vivaldi", "Dia"]

// The open page as text: the thread on Gmail, otherwise the main content, plus any highlighted text.
let PAGE_JS = "(function(){var nl=String.fromCharCode(10);var sel=String(window.getSelection()||'');var el=null;if(location.hostname==='mail.google.com'){el=document.querySelector('div[role=main]');}el=el||document.querySelector('main,[role=main],article')||document.body;var t=(el&&el.innerText)||'';return (sel?('HIGHLIGHTED TEXT:'+nl+sel+nl+nl):'')+t.slice(0,20000);})()"
let SPLIT = "<<<QA-SPLIT>>>"

func browserPage(_ app: String) -> (url: String, text: String)? {
    let script: String
    if CHROMIUM.contains(app) {
        script = """
        tell application "\(app)"
          set t to active tab of front window
          return (URL of t) & "\(SPLIT)" & (execute t javascript "\(PAGE_JS)")
        end tell
        """
    } else if app == "Safari" {
        script = """
        tell application "Safari"
          set t to current tab of front window
          return (URL of t) & "\(SPLIT)" & (do JavaScript "\(PAGE_JS)" in t)
        end tell
        """
    } else {
        return nil
    }
    let r = run("/usr/bin/osascript", ["-e", script])
    guard r.code == 0, let cut = r.out.range(of: SPLIT) else {
        if !r.err.isEmpty { log("page read failed for \(app): \(r.err.prefix(200))") }
        return nil
    }
    return (String(r.out[..<cut.lowerBound]), String(r.out[cut.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Text read off the screenshot with macOS's built-in text recognition, top to bottom.
func ocr(_ path: String) -> String? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

func addText(to screen: inout Screen) {
    let start = Date()
    if let page = browserPage(screen.app) {
        screen.url = page.url
        if !page.text.isEmpty { screen.text = page.text; screen.textSource = "page" }
    }
    if screen.text == nil, let t = ocr(screen.path) {
        screen.text = String(t.prefix(20000))
        screen.textSource = "ocr"
    }
    log("context \(screen.app) \(screen.textSource) \(screen.text?.count ?? 0) chars in \(Int(Date().timeIntervalSince(start) * 1000))ms")
}

func describe(_ s: Screen, maxText: Int) -> String {
    var lines = ["App: \(s.app)"]
    if !s.title.isEmpty { lines.append("Window: \(s.title)") }
    if let u = s.url { lines.append("URL: \(u)") }
    if let t = s.text {
        let label = s.textSource == "page" ? "Text of the open page (read from the browser)" : "Text on screen (read off the screenshot, may have small errors)"
        lines.append("\(label):\n\(t.prefix(maxText))")
    }
    return lines.joined(separator: "\n")
}

/// Screens captured when a page opened, so the answer uses what was in front at that moment,
/// not the launcher. Keyed by the page's session id.
final class Sessions {
    static let shared = Sessions()
    private let lock = NSLock()
    private var screens: [String: Screen?] = [:]
    private var waiting: [String: [(Screen?) -> Void]] = [:]

    func capture() -> String {
        let id = UUID().uuidString
        lock.lock(); waiting[id] = []; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let s = captureScreen()
            self.lock.lock()
            self.screens[id] = s
            let calls = self.waiting.removeValue(forKey: id) ?? []
            self.lock.unlock()
            calls.forEach { $0(s) }
        }
        return id
    }

    /// The screen for `id`, as soon as it's captured.
    func screen(_ id: String, _ done: @escaping (Screen?) -> Void) {
        lock.lock()
        if let s = screens[id] { lock.unlock(); done(s); return }
        if waiting[id] != nil { waiting[id]!.append(done); lock.unlock(); return }
        lock.unlock()
        done(nil)
    }
}

// MARK: - Fast model

struct Turn { let question: String; let answer: String }

let RULES = """
You are Samin's quick assistant inside his Mac launcher. Be fast and concise: plain language, short answers, markdown only when it helps (lists, code).
His first message comes with a live screenshot of the window he is looking at right now, plus the text of that page or window (an email thread, a doc, a chat, code). That IS his screen: use it whenever the question could be about what he's looking at ("this", "here", "reply to this", "what does this mean", "summarize", "what's on my screen"). Never say you can't see his screen or that no screenshot is attached when one is. Don't describe the screen unless he asks.

"""
let TOOL_RULES = """
You know Samin (below) and can look things up with tools: his GitHub repos, what's remembered about his work (Honcho), his files and email (DigUp) and his open Chrome tabs. When he asks for a link, a repo, a file or "where is X", use the tools instead of telling him where to look. Give the exact link as a markdown link, first thing, then at most a line about it. If several fit, list the best few as links. For files, give the full path in backticks. Don't announce that you're searching; just search and answer.
"""
let HANDOFF_RULE = "If the request is real work on his computer, not a question you can answer from what you know or see (editing or creating files, running commands, writing or fixing code, building something, research across many sources, anything that would take an agent more than a minute), do not attempt it. Reply with exactly one line: \(HANDOFF) <short title for the task>"

func content(_ text: String, _ s: Screen?) -> Any {
    guard let s else { return text }
    var blocks: [[String: Any]] = []
    if let data = FileManager.default.contents(atPath: s.path) {
        blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]])
    }
    blocks.append(["type": "text", "text": "<what_samin_is_looking_at>\n[The image above is a live screenshot of this window.]\n\(describe(s, maxText: 20000))\n</what_samin_is_looking_at>\n\nSamin asks: \(text)"])
    return blocks
}

// MARK: - Knowing Samin

/// Who Samin is (his Honcho peer card) and his GitHub repos, fetched in the background and kept.
final class Knowledge {
    static let shared = Knowledge()
    private let lock = NSLock()
    private var card: [String] = []
    private var repos: [[String: String]] = []
    private var fetchedAt = Date.distantPast

    func refresh() {
        guard Date().timeIntervalSince(fetchedAt) > 30 * 60 else { return }
        fetchedAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let card = (honcho("GET", "/peers/samin/card", nil) as? [String: Any])?["peer_card"] as? [String] ?? []
            var repos: [[String: String]] = []
            for owner in GITHUB_OWNERS {
                let r = run(GH, ["repo", "list", owner, "--limit", "300", "--json", "nameWithOwner,description,url,updatedAt"])
                for item in (try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]]) ?? [] {
                    repos.append(["name": item["nameWithOwner"] as? String ?? "", "url": item["url"] as? String ?? "",
                                  "about": item["description"] as? String ?? "", "updated": item["updatedAt"] as? String ?? ""])
                }
            }
            self.lock.lock()
            if !card.isEmpty { self.card = card }
            if !repos.isEmpty { self.repos = repos }
            self.lock.unlock()
            log("knowledge: \(card.count) card lines, \(repos.count) repos")
        }
    }

    var profile: String { lock.lock(); defer { lock.unlock() }; return card.joined(separator: "\n") }

    /// Repos whose name or description share the most words with `q`.
    func findRepos(_ q: String) -> [[String: String]] {
        lock.lock(); let all = repos; lock.unlock()
        let words = q.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        let scored = all.map { r -> (Int, [String: String]) in
            let hay = "\(r["name"] ?? "") \(r["about"] ?? "")".lowercased()
            let name = (r["name"] ?? "").lowercased()
            return (words.reduce(0) { $0 + (name.contains($1) ? 3 : hay.contains($1) ? 1 : 0) }, r)
        }
        return scored.filter { $0.0 > 0 }.sorted { $0.0 > $1.0 }.prefix(8).map { $0.1 }
    }
}

func honcho(_ method: String, _ path: String, _ body: [String: Any]?) -> Any? {
    guard let d = FileManager.default.contents(atPath: home + "/.honcho/config.json"),
          let cfg = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let key = cfg["apiKey"] as? String else { return nil }
    let ws = cfg["workspace"] as? String ?? "samin-shared"
    var req = URLRequest(url: URL(string: "https://api.honcho.dev/v3/workspaces/\(ws)\(path)")!, timeoutInterval: 6)
    req.httpMethod = method
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { req.httpBody = jsonData(body) }
    let sem = DispatchSemaphore(value: 0)
    var out: Any?
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let data { out = try? JSONSerialization.jsonObject(with: data) }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 7)
    return out
}

// MARK: - Tools Haiku can call

let TOOLS: [[String: Any]] = [
    ["name": "find_repo", "description": "Find one of Samin's GitHub repos (his own and the AI-Answer and creatorauthority orgs) by words in its name or description. Returns names, URLs and descriptions.",
     "input_schema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
    ["name": "recall", "description": "Search what's remembered about Samin's work and life (Honcho memory): projects, people, decisions, where things are, links he's mentioned.",
     "input_schema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
    ["name": "search_files", "description": "Search Samin's Mac by meaning with DigUp: documents, PDFs, screenshots, images, recordings, his last year of Gmail and his Google Drive. Returns paths and excerpts.",
     "input_schema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
    ["name": "chrome_tabs", "description": "List Samin's open Chrome tabs (title and URL) whose title or URL contains any of the words.",
     "input_schema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
]

let TOOL_STATUS = ["find_repo": "Looking through your GitHub", "recall": "Checking what I remember", "search_files": "Searching your files with DigUp", "chrome_tabs": "Looking at your Chrome tabs"]

func runTool(_ name: String, _ input: [String: Any]) -> String {
    let q = input["query"] as? String ?? ""
    switch name {
    case "find_repo":
        let hits = Knowledge.shared.findRepos(q)
        return hits.isEmpty ? "No repo matched. Try other words." : hits.map { "\($0["name"]!) — \($0["url"]!)\(($0["about"] ?? "").isEmpty ? "" : " — \($0["about"]!)")" }.joined(separator: "\n")
    case "recall":
        let res = honcho("POST", "/conclusions/query", ["query": q, "top_k": 8, "filters": ["observer": "samin", "observed": "samin"]])
        let items = (res as? [[String: Any]]) ?? ((res as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.isEmpty ? "Nothing remembered about that." : items.compactMap { $0["content"] as? String }.map { "- \($0)" }.joined(separator: "\n")
    case "search_files":
        let sem = DispatchSemaphore(value: 0)
        var reply: [String: Any]?
        DigUp.shared.search(q) { reply = $0; sem.signal() }
        _ = sem.wait(timeout: .now() + 20)
        let hits = (reply?["hits"] as? [[String: Any]] ?? []).prefix(6)
        return hits.isEmpty ? "DigUp found nothing." : hits.map { h in
            let ex = (h["excerpt"] as? String ?? "").replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "").prefix(240)
            return "\(h["kind"] as? String ?? "") \(h["path"] as? String ?? "")\n  \(ex)"
        }.joined(separator: "\n")
    case "chrome_tabs":
        let r = run("/usr/bin/osascript", ["-e", """
        set out to ""
        tell application "Google Chrome"
          repeat with w in windows
            repeat with t in tabs of w
              set out to out & (title of t) & "\t" & (URL of t) & linefeed
            end repeat
          end repeat
        end tell
        return out
        """])
        let words = q.lowercased().split(separator: " ").map(String.init)
        let tabs = r.out.split(separator: "\n").filter { line in words.contains { line.lowercased().contains($0) } }.prefix(12)
        return tabs.isEmpty ? "No open tab matched." : tabs.map { $0.replacingOccurrences(of: "\t", with: " — ") }.joined(separator: "\n")
    default:
        return "Unknown tool."
    }
}

/// One answer, with tool calls as needed. `emit` gets text pieces and tool status lines as they come.
func agentAnswer(_ question: String, history: [Turn], screen: Screen?, allowHandoff: Bool,
                 onDelta: @escaping (String) -> Void, onStatus: @escaping (String) -> Void) async throws -> String {
    var messages: [[String: Any]] = []
    // The screen rides on the first question of the conversation.
    for (i, t) in history.enumerated() {
        messages.append(["role": "user", "content": content(t.question, i == 0 ? screen : nil)])
        messages.append(["role": "assistant", "content": t.answer.isEmpty ? "(no answer)" : t.answer])
    }
    messages.append(["role": "user", "content": content(question, history.isEmpty ? screen : nil)])
    let profile = Knowledge.shared.profile
    var system = RULES + (allowHandoff ? HANDOFF_RULE : "Always answer directly here.") + "\n\n" + TOOL_RULES
    if !profile.isEmpty { system += "\n\nWhat you know about Samin:\n\(profile)" }
    var full = ""

    for _ in 0..<4 {
        let body: [String: Any] = [
            "model": MODEL, "max_tokens": 4096, "thinking": ["type": "disabled"], "stream": true,
            "system": system, "messages": messages, "tools": TOOLS,
        ]
        var req = URLRequest(url: URL(string: PROXY + "/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey(), forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = jsonData(body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            var s = ""
            for try await l in bytes.lines { s += l; if s.count > 300 { break } }
            throw NSError(domain: "QuickAsk", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "CLIProxyAPI \(h.statusCode): \(s.prefix(300))"])
        }
        // This turn's content blocks, by index: text, or a tool call whose input arrives as JSON pieces.
        var blocks: [Int: [String: Any]] = [:]
        var toolJSON: [Int: String] = [:]
        var stop = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let d = String(line.dropFirst(5)).data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let i = ev["index"] as? Int ?? 0
            switch ev["type"] as? String {
            case "content_block_start":
                blocks[i] = ev["content_block"] as? [String: Any] ?? [:]
                if blocks[i]?["type"] as? String == "tool_use" {
                    toolJSON[i] = ""
                    // Whatever it said before looking ("Let me check…") is dropped; the page clears it on a status.
                    full = ""
                    onStatus(TOOL_STATUS[blocks[i]?["name"] as? String ?? ""] ?? "Looking it up")
                }
            case "content_block_delta":
                let delta = ev["delta"] as? [String: Any] ?? [:]
                if delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                    let sofar = blocks[i]?["text"] as? String ?? ""
                    blocks[i]?["text"] = sofar + t
                    full += t
                    onDelta(t)
                } else if delta["type"] as? String == "input_json_delta", let pj = delta["partial_json"] as? String {
                    toolJSON[i, default: ""] += pj
                }
            case "message_delta":
                stop = (ev["delta"] as? [String: Any])?["stop_reason"] as? String ?? stop
            case "error":
                let msg = (ev["error"] as? [String: Any])?["message"] as? String ?? "Model error"
                throw NSError(domain: "QuickAsk", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
            default:
                break
            }
        }
        guard stop == "tool_use" else { return full }

        var assistant: [[String: Any]] = []
        var results: [[String: Any]] = []
        for i in blocks.keys.sorted() {
            var b = blocks[i]!
            if b["type"] as? String == "tool_use" {
                let input = (try? JSONSerialization.jsonObject(with: Data((toolJSON[i] ?? "").utf8))) as? [String: Any] ?? [:]
                b["input"] = input
                let name = b["name"] as? String ?? ""
                let t0 = Date()
                let out = runTool(name, input)
                log("tool \(name)(\(input["query"] as? String ?? "")) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                results.append(["type": "tool_result", "tool_use_id": b["id"] as? String ?? "", "content": out])
            } else if (b["text"] as? String ?? "").isEmpty {
                continue
            }
            assistant.append(b)
        }
        messages.append(["role": "assistant", "content": assistant])
        messages.append(["role": "user", "content": results])
    }
    return full
}

// MARK: - T3 Code

func taskForT3(_ question: String, history: [Turn], screen: Screen?) -> String {
    var parts = [question.trimmingCharacters(in: .whitespacesAndNewlines)]
    if !history.isEmpty {
        let convo = history.map { "Me: \($0.question)\nQuick model: \($0.answer)" }.joined(separator: "\n\n")
        parts.append("Context, from a quick chat I had before this:\n\n\(convo)")
    }
    if let s = screen {
        parts.append("What I was looking at:\n\(describe(s, maxText: 8000))\nScreenshot: \(s.path)")
    }
    return parts.joined(separator: "\n\n")
}

/// Starts a thread in the default project with its default model and settings, then opens it.
/// Returns an error message on failure.
func startT3(_ message: String, title: String) -> String? {
    let t = String((title.split(separator: "\n").first.map(String.init) ?? title).prefix(80))
    let r = run(T3, ["thread", "start", PROJECT, "-", "--json", "--title", t.isEmpty ? "Quick Ask task" : t], input: message, cwd: PROJECT)
    if r.code != 0 { return r.err.isEmpty ? "t3 exited with \(r.code)" : r.err }
    var threadId: String?
    if let d = r.out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        let th = (j["thread"] as? [String: Any]) ?? j
        threadId = (th["threadId"] ?? th["id"]) as? String
    }
    let env = (try? String(contentsOfFile: home + "/.t3/userdata/environment-id", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let threadId, !env.isEmpty,
       let id = threadId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))),
       let url = URL(string: "t3code://threads/\(env)/\(id)") {
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    } else {
        DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/T3 Code (Nightly).app")) }
    }
    log("started T3 thread \(threadId ?? "?") — \(t)")
    return nil
}

// MARK: - DigUp

/// `digup search-service`, kept running so the index stays open and the model warm.
/// One JSON request per line in, the reply on a line out with the request's id.
final class DigUp {
    static let shared = DigUp()
    private let queue = DispatchQueue(label: "digup")
    private var proc: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: ([String: Any]?) -> Void] = [:]
    private var shown = Set<String>()

    func listed(_ path: String) -> Bool { queue.sync { shown.contains(path) } }

    private func roots() -> (roots: [String], code: [String], index: String?) {
        let r = run("/usr/bin/defaults", ["export", "com.abdurrahim.DigUp", "-"])
        var roots = [home], code: [String] = [], index: String?
        if let d = r.out.data(using: .utf8),
           let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
            if let a = p["roots"] as? [String], !a.isEmpty { roots = a }
            code = p["codeRoots"] as? [String] ?? []
            index = p["indexDir"] as? String
        }
        return (roots, code, index)
    }

    private func start() {
        guard proc == nil, FileManager.default.isExecutableFile(atPath: DIGUP) else { return }
        let cfg = roots()
        var args = ["search-service"] + cfg.roots
        if let i = cfg.index, !i.isEmpty { args += ["--index", (i as NSString).expandingTildeInPath] }
        let indexDir = (cfg.index.map { ($0 as NSString).expandingTildeInPath }) ?? home + "/Library/Application Support/DigUp/index.noindex"
        // Code folders only when the code index exists; otherwise the service would create an empty one.
        if FileManager.default.fileExists(atPath: indexDir + "/code.sqlite") { for c in cfg.code { args += ["--code-root", c] } }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: DIGUP)
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardInput = inp; p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            self?.queue.async { self?.receive(d) }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.proc = nil; self?.stdin = nil
                self?.pending.values.forEach { $0(nil) }
                self?.pending = [:]
            }
        }
        do { try p.run() } catch { log("digup failed to start: \(error)"); return }
        proc = p
        stdin = inp.fileHandleForWriting
        log("digup search-service started")
    }

    private func receive(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = j["id"] as? Int else { continue }
            for h in j["hits"] as? [[String: Any]] ?? [] { if let p = h["path"] as? String { shown.insert(p) } }
            pending.removeValue(forKey: id)?(j)
        }
    }

    func search(_ q: String, done: @escaping ([String: Any]?) -> Void) {
        queue.async {
            self.start()
            guard let stdin = self.stdin else { done(nil); return }
            let id = self.nextId; self.nextId += 1
            self.pending[id] = done
            var req = jsonData(["id": id, "op": "search", "q": q, "meaning": true, "limit": 30])
            req.append(10)
            stdin.write(req)
            self.queue.asyncAfter(deadline: .now() + 20) {
                self.pending.removeValue(forKey: id)?(nil)
            }
        }
    }
}

// MARK: - Local server

/// One request per connection, closed after the reply. Bound to 127.0.0.1 only.
final class Server {
    let listener: NWListener

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: PORT)!)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { Connection($0).start() }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { log("server failed: \(e)") }
        }
        listener.start(queue: .global(qos: .userInitiated))
        log("listening on 127.0.0.1:\(PORT)")
    }
}

final class Connection {
    let c: NWConnection
    var data = Data()

    init(_ c: NWConnection) { self.c = c }

    func start() {
        c.start(queue: .global(qos: .userInitiated))
        read()
    }

    private func read() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] chunk, _, done, err in
            if let chunk { data.append(chunk) }
            if let head = data.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: data[..<head.lowerBound], as: UTF8.self)
                let length = header.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = data[head.upperBound...]
                if body.count >= length { handle(header: header, body: Data(body.prefix(length))); return }
            }
            if done || err != nil { c.cancel(); return }
            read()
        }
    }

    func send(_ status: String, _ type: String, _ body: Data) {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { [c] _ in c.cancel() })
    }

    /// A reply written as it's produced: JSON lines, ended by closing the connection.
    func beginStream() {
        c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8), completion: .idempotent)
    }

    func streamLine(_ v: [String: Any]) {
        var d = jsonData(v); d.append(10)
        c.send(content: d, completion: .idempotent)
    }

    func endStream() {
        c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [c] _ in c.cancel() })
    }

    private func handle(header: String, body: Data) {
        let lines = header.split(separator: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return send("400 Bad Request", "text/plain", Data()) }
        let method = String(parts[0])
        let target = parts[1].split(separator: "?", maxSplits: 1)
        let path = String(target[0])
        let query = queryItems(target.count > 1 ? target[1] : nil)
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { headers[kv[0].lowercased()] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        // Only our own host name: no DNS rebinding.
        guard headers["host"] == "127.0.0.1:\(PORT)" || headers["host"] == "localhost:\(PORT)" else {
            return send("403 Forbidden", "text/plain", Data())
        }
        // Actions need a header a cross-site page can't send without a preflight we never answer.
        if path.hasPrefix("/api/"), headers["x-quickask"] != "1" { return send("403 Forbidden", "text/plain", Data()) }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        switch (method, path) {
        case ("GET", "/ask"), ("GET", "/digup"), ("GET", "/codes"):
            let page = path == "/ask" ? "ask.html" : path == "/digup" ? "digup.html" : "codes.html"
            guard let url = Bundle.main.url(forResource: page, withExtension: nil),
                  var html = try? String(contentsOf: url, encoding: .utf8) else { return send("404 Not Found", "text/plain", Data()) }
            // Ask captures the screen now, while the window you were in is still in front.
            let sid = path == "/ask" ? Sessions.shared.capture() : ""
            if path != "/codes" { Knowledge.shared.refresh() }
            let boot: [String: Any] = ["q": query["q"] ?? "", "sid": sid, "floating": query["floating"] == "1", "home": home]
            html = html.replacingOccurrences(of: "/*BOOT*/", with: "window.BOOT = \(String(decoding: jsonData(boot), as: UTF8.self));")
            send("200 OK", "text/html; charset=utf-8", Data(html.utf8))
        case ("GET", "/marked.min.js"):
            guard let url = Bundle.main.url(forResource: "marked.min", withExtension: "js"), let d = try? Data(contentsOf: url) else {
                return send("404 Not Found", "text/plain", Data())
            }
            send("200 OK", "text/javascript", d)
        case ("GET", "/thumb"):
            // Pictures for DigUp's results, and only for files DigUp just listed.
            let p = query["path"] ?? ""
            guard DigUp.shared.listed(p) else { return send("404 Not Found", "text/plain", Data()) }
            let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: p), size: CGSize(width: 88, height: 88), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [self] rep, _ in
                guard let cg = rep?.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                    return send("404 Not Found", "text/plain", Data())
                }
                send("200 OK", "image/png", png)
            }
        case ("POST", "/api/ask"):
            ask(json)
        case ("POST", "/api/t3"):
            let q = json["q"] as? String ?? ""
            let history = turns(json["history"])
            Sessions.shared.screen(json["sid"] as? String ?? "") { [self] s in
                let err = startT3(taskForT3(q, history: history, screen: s), title: json["title"] as? String ?? q)
                send("200 OK", "application/json", jsonData(err.map { ["error": $0] } ?? ["ok": true]))
            }
        case ("GET", "/api/codes"):
            let minutes = min(1440, max(1, Int(query["minutes"] ?? "30") ?? 30))
            Codes.shared.search(minutes) { [self] reply in
                send("200 OK", "application/json", jsonData(reply))
            }
        case ("POST", "/api/digup"):
            DigUp.shared.search(json["q"] as? String ?? "") { [self] reply in
                send("200 OK", "application/json", jsonData(reply ?? ["error": "DigUp didn't answer. Is DigUp installed and indexed?"]))
            }
        case ("POST", "/api/open"):
            let p = json["path"] as? String ?? ""
            guard FileManager.default.fileExists(atPath: p) else { return send("404 Not Found", "application/json", jsonData(["error": "Not found"])) }
            DispatchQueue.main.async {
                if json["reveal"] as? Bool == true {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: p))
                }
            }
            send("200 OK", "application/json", jsonData(["ok": true]))
        case ("POST", "/api/open-url"):
            guard let u = URL(string: json["url"] as? String ?? ""), ["http", "https"].contains(u.scheme ?? "") else {
                return send("400 Bad Request", "application/json", jsonData(["error": "Not a web link"]))
            }
            DispatchQueue.main.async {
                if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                    NSWorkspace.shared.open([u], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(u)
                }
            }
            send("200 OK", "application/json", jsonData(["ok": true]))
        case ("POST", "/api/copy"):
            let text = json["text"] as? String ?? ""
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                let ok = NSPasteboard.general.setString(text, forType: .string)
                self.send("200 OK", "application/json", jsonData(["ok": ok]))
            }
        default:
            send("404 Not Found", "text/plain", Data())
        }
    }

    private func turns(_ v: Any?) -> [Turn] {
        (v as? [[String: Any]] ?? []).map { Turn(question: $0["q"] as? String ?? "", answer: $0["a"] as? String ?? "") }
    }

    /// Streams `{screen}`, then `{d: text}` pieces, then `{done}`, `{handoff: title}` (a T3 thread was
    /// started instead) or `{error}`.
    private func ask(_ json: [String: Any]) {
        let q = json["q"] as? String ?? ""
        let history = turns(json["history"])
        let mode = json["mode"] as? String ?? "auto"
        beginStream()
        Sessions.shared.screen(json["sid"] as? String ?? "") { [self] s in
            if history.isEmpty {
                streamLine(["screen": ["app": s?.app ?? "", "title": s?.title ?? "", "how": s?.how ?? "", "ok": s != nil]])
            }
            if mode == "t3" {
                let err = startT3(taskForT3(q, history: history, screen: s), title: q)
                streamLine(err.map { ["error": $0] } ?? ["handoff": q])
                return endStream()
            }
            Task {
                do {
                    // Held back until it can't be the hand-off marker.
                    var held = "", sure = false
                    let full = try await agentAnswer(q, history: history, screen: s, allowHandoff: mode != "answer", onDelta: { piece in
                        if sure { self.streamLine(["d": piece]); return }
                        held += piece
                        let t = held.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.count >= HANDOFF.count || !HANDOFF.hasPrefix(t) {
                            if !t.hasPrefix(HANDOFF) { sure = true; self.streamLine(["d": held]) }
                        }
                    }, onStatus: { self.streamLine(["status": $0]) })
                    let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
                    if mode != "answer", trimmed.hasPrefix(HANDOFF) {
                        let title = trimmed.dropFirst(HANDOFF.count).split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? q
                        let err = startT3(taskForT3(q, history: history, screen: s), title: title.isEmpty ? q : title)
                        self.streamLine(err.map { ["error": $0] } ?? ["handoff": title.isEmpty ? q : title])
                    } else {
                        if !sure, !held.isEmpty { self.streamLine(["d": held]) }
                        self.streamLine(["done": true])
                    }
                } catch {
                    self.streamLine(["error": error.localizedDescription])
                }
                self.endStream()
            }
        }
    }
}

// MARK: - Floating window (quickask://answer, and ⌘↩ from SamSearch)

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class FloatingAnswer: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    static let shared = FloatingAnswer()
    private var panel: KeyPanel!
    private var web: WKWebView!
    private var shownAt = Date.distantPast

    private func setup() {
        let rect = NSRect(x: 0, y: 0, width: 720, height: 470)
        // Non-activating, like a launcher: takes the keyboard without pulling focus from the app you were in.
        panel = KeyPanel(contentRect: rect, styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let fx = NSVisualEffectView(frame: rect)
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "qa")
        web = WKWebView(frame: rect, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        fx.addSubview(web)
        panel.contentView = fx
    }

    func open(question: String) {
        if panel == nil { setup() }
        var c = URLComponents(string: "http://127.0.0.1:\(PORT)/ask")!
        c.queryItems = [URLQueryItem(name: "q", value: question), URLQueryItem(name: "floating", value: "1")]
        web.load(URLRequest(url: c.url!))
        let mouse = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let f = scr.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - f.height * 0.14))
        shownAt = Date()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(web)
    }

    func close() { panel?.orderOut(nil); web?.loadHTMLString("", baseURL: nil) }

    // Clicking anywhere else closes it. Ignore the focus shuffle right after it opens.
    func windowDidResignKey(_ notification: Notification) {
        if Date().timeIntervalSince(shownAt) > 0.6 { close() }
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        if (message.body as? [String: Any])?["type"] as? String == "close" { close() }
    }
}

// MARK: - App

func route(_ url: URL) {
    log("open \(url.absoluteString.prefix(300))")
    let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems?.first { $0.name == "q" }?.value ?? ""
    let text = formValue(raw)
    switch url.host {
    case "t3-thread-create":
        guard !text.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let s = captureScreen()
            if let err = startT3(taskForT3(text, history: [], screen: s), title: text) {
                log("T3 error: \(err)")
                DispatchQueue.main.async {
                    let a = NSAlert(); a.messageText = "Couldn't start a T3 thread"; a.informativeText = err
                    NSApp.activate(ignoringOtherApps: true); a.runModal()
                }
            }
        }
    default:
        FloatingAnswer.shared.open(question: text)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: Server?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Screenshots of the window behind need Screen Recording; this puts Quick Ask in that list and asks once.
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        do { server = try Server() } catch { log("server didn't start: \(error)") }
        Knowledge.shared.refresh()
        // An Edit menu so copy, paste and select-all work in the pages.
        let main = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
        main.addItem(appItem); main.addItem(editItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Quick Ask", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(route)
    }
}

// Tests and a server-only check need no app, screen capture or background tools.
if CommandLine.arguments.contains("--selftest-codes") { selftestCodes(); exit(0) }
if CommandLine.arguments.contains("--serve-codes") {
    do {
        let server = try Server()
        withExtendedLifetime(server) { RunLoop.main.run() }
    } catch { fputs("server didn't start: \(error)\n", stderr); exit(1) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
