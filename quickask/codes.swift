// MARK: - 2FA codes

import Cocoa
import SQLite3

/// Plain text from Gmail's previews, including numeric HTML entities.
func codeText(_ html: String) -> String {
    var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—"]
    let rx = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
    for m in rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard let r = Range(m.range, in: text), let key = Range(m.range(at: 1), in: text) else { continue }
        let name = String(text[key])
        let number = name.hasPrefix("#x") ? UInt32(name.dropFirst(2), radix: 16) : name.hasPrefix("#") ? UInt32(name.dropFirst()) : nil
        if let value = number.flatMap(UnicodeScalar.init).map(String.init) ?? entities[name] { text.replaceSubrange(r, with: value) }
    }
    return text
}

/// The most likely code in one message; context beats the first number.
func extractCode(_ text: String) -> String? {
    let ns = text as NSString
    func matches(_ pattern: String) -> [NSTextCheckingResult] {
        (try! NSRegularExpression(pattern: pattern)).matches(in: text, range: NSRange(location: 0, length: ns.length))
    }
    let excluded = matches(#"(?i)(?:https?://|www\.)\S+|\b[\w.-]+\.[a-z]{2,}/\S*|\b\d{1,4}[/.-]\d{1,2}[/.-]\d{2,4}\b|\b\d{1,2}:\d{2,4}(?::\d{2})?\b|[$€£]\s*[\d,.]+|\b\d+[.,]?\d*\s*%|\+?\d[\d ()-]{8,}\d|\b[A-Z]{2}\s+\d{5}(?:-\d{4})?\b"#).map(\.range)
    let keywords = matches(#"(?i)\b(?:code|verification|verify|otp|passcode|pin|one[ -]time|security|2fa|login|sign[ -]?in|log[ -]?in)\b|\bis\s*:|:"#).map(\.range)
    let candidates = matches(#"(?<![A-Za-z0-9])(?:[0-9]{2,4}[ -][0-9]{2,4}|[0-9]{4,8}|[A-Z0-9]{6})(?![A-Za-z0-9])"#)
    var best: (String, Int)?
    for m in candidates {
        let r = m.range
        if excluded.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
        let raw = ns.substring(with: r)
        let code = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        let digits = code.filter { $0.isNumber }.count
        guard (4...8).contains(code.count), digits == code.count || (code.count == 6 && digits >= 2) else { continue }
        let before = ns.substring(with: NSRange(location: max(0, r.location - 40), length: min(40, r.location)))
        let after = ns.substring(from: NSMaxRange(r)).prefix(48)
        if code.count == 4, let n = Int(code), (1900...2099).contains(n) {
            let labelled = before.range(of: #"(?i)\b(?:code|otp|passcode|pin)(?:\s+is)?\s*[:=-]?\s*$"#, options: .regularExpression) != nil
            let followed = after.range(of: #"(?i)^\s+is\s+your\s+(?:verification\s+|security\s+)?code\b"#, options: .regularExpression) != nil
            if !labelled && !followed { continue }
        }
        if before.range(of: #"(?i)(?:\b(?:order|invoice|receipt|tracking|phone|call|zip)(?:\s+(?:number|no\.?))?\s*[:#-]?\s*|#\s*)$"#, options: .regularExpression) != nil { continue }
        if before.range(of: #"\d[-.( /]+$"#, options: .regularExpression) != nil || after.range(of: #"^[-.)/]+\d"#, options: .regularExpression) != nil { continue }
        let distances = keywords.map { k -> Int in
            if NSMaxRange(k) <= r.location { return r.location - NSMaxRange(k) }
            return max(0, k.location - NSMaxRange(r)) + 8
        }
        guard let distance = distances.min(), distance <= 64 else { continue }
        let score = 100 - distance + (code.count == 6 ? 4 : 0)
        if best == nil || score > best!.1 { best = (code, score) }
    }
    return best?.0
}

struct CodeHit {
    let id: String
    let code: String
    let source: String
    let sender: String
    let subject: String
    let snippet: String
    let time: Date

    var json: [String: Any] {
        ["id": id, "code": code, "source": source, "sender": sender, "subject": subject, "snippet": snippet, "time": time.timeIntervalSince1970]
    }
}

struct CodeSource {
    let source: String
    var hits: [CodeHit] = []
    var error: String? = nil

    var json: [String: Any] {
        var out: [String: Any] = ["source": source, "count": hits.count]
        if let error { out["error"] = error }
        return out
    }
}

/// The CLI runs from a GUI app, with its own PATH and a bounded wait.
func codeMailCommand(_ alias: String) -> (out: Data, error: String?) {
    let p = Process(), out = Pipe(), err = Pipe()
    p.executableURL = URL(fileURLWithPath: home + "/.local/bin/composio")
    let query = #"newer_than:1d -category:promotions -category:social (code OR verification OR verify OR OTP OR passcode OR 2FA OR "one-time" OR "sign in" OR "log in" OR login OR security)"#
    p.arguments = ["execute", "GMAIL_FETCH_EMAILS", "--account", alias, "-d", String(decoding: jsonData(["query": query, "max_results": 10, "include_payload": false, "verbose": false]), as: UTF8.self)]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = home + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = err
    do { try p.run() } catch { return (Data(), error.localizedDescription) }
    let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: timeout)
    let group = DispatchGroup()
    group.enter()
    // Drain stderr too: neither pipe should hold up the other.
    DispatchQueue.global().async { _ = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit(); timeout.cancel(); group.wait()
    return (data, p.terminationStatus == 0 ? nil : "Composio exited with \(p.terminationStatus) (or timed out). Check the \(alias) Gmail connection.")
}

func mailCodes(_ alias: String, email: String, since: Date) -> CodeSource {
    var result = CodeSource(source: "Gmail · " + email)
    let reply = codeMailCommand(alias)
    if let error = reply.error { result.error = error; return result }
    guard let j = try? JSONSerialization.jsonObject(with: reply.out) as? [String: Any], j["successful"] as? Bool == true,
          let data = j["data"] as? [String: Any], let messages = data["messages"] as? [[String: Any]] else {
        result.error = "Composio didn't return Gmail messages. Check the \(alias) Gmail connection."
        return result
    }
    let iso = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for m in messages {
        let stamp = m["messageTimestamp"] as? String ?? ""
        guard let time = fractional.date(from: stamp) ?? iso.date(from: stamp), time >= since else { continue }
        let preview = m["preview"] as? [String: Any] ?? [:]
        let subject = codeText(m["subject"] as? String ?? preview["subject"] as? String ?? "")
        let snippet = codeText(preview["body"] as? String ?? "")
        guard let code = extractCode(subject + "\n" + snippet) else { continue }
        result.hits.append(CodeHit(id: "gmail:\(alias):\(m["messageId"] as? String ?? stamp)", code: code, source: result.source,
                                   sender: codeText(m["sender"] as? String ?? ""), subject: subject, snippet: String(snippet.prefix(300)), time: time))
    }
    return result
}

/// Old Messages rows keep their text in an archived attributed string.
/// The Objective-C boundary catches malformed archives before trying readable strings.
func messageCodeText(_ blob: Data) -> String {
    if let text = codeArchiveText(blob) { return text }
    let bytes = [UInt8](blob)
    let marker = Array("NSString".utf8)
    guard bytes.count >= marker.count else { return "" }
    for i in 0...(bytes.count - marker.count) where Array(bytes[i..<(i + marker.count)]) == marker {
        var start: Int?, strings: [String] = []
        for j in (i + marker.count)..<bytes.count {
            if bytes[j] >= 32 && bytes[j] < 127 || bytes[j] == 10 {
                if start == nil { start = j }
            } else if let s = start {
                if j - s >= 4 { strings.append(String(decoding: bytes[s..<j], as: UTF8.self)) }
                start = nil
            }
        }
        if let s = start { strings.append(String(decoding: bytes[s...], as: UTF8.self)) }
        return strings.joined(separator: "\n")
    }
    return ""
}

func messageCodes(since: Date, path: String = home + "/Library/Messages/chat.db") -> CodeSource {
    var result = CodeSource(source: "Messages")
    var db: OpaquePointer?
    let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro&immutable=0"
    let status = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    defer { if let db { sqlite3_close(db) } }
    func failed() -> CodeSource {
        let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Couldn't open chat.db"
        if reason.lowercased().contains("authorization") || reason.lowercased().contains("permission") || status == SQLITE_AUTH || status == SQLITE_PERM {
            result.error = "Messages needs Full Disk Access for SamSearch — System Settings › Privacy & Security › Full Disk Access (\(reason))"
        } else {
            result.error = "Couldn't read Messages: \(reason)"
        }
        return result
    }
    guard status == SQLITE_OK, let db else { return failed() }
    sqlite3_busy_timeout(db, 300)
    let sql = """
    SELECT message.ROWID, message.text, message.attributedBody, message.date, handle.id
    FROM message LEFT JOIN handle ON message.handle_id = handle.ROWID
    WHERE message.is_from_me = 0 AND message.date >= ? ORDER BY message.date DESC
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return failed() }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSinceReferenceDate * 1_000_000_000))
    var step = sqlite3_step(stmt)
    while step == SQLITE_ROW {
        var text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        if text.isEmpty, let blob = sqlite3_column_blob(stmt, 2) {
            text = messageCodeText(Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2))))
        }
        if let code = extractCode(text) {
            let sender = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "Unknown sender"
            let time = Date(timeIntervalSinceReferenceDate: Double(sqlite3_column_int64(stmt, 3)) / 1_000_000_000)
            result.hits.append(CodeHit(id: "messages:\(sqlite3_column_int64(stmt, 0))", code: code, source: "Messages · " + sender,
                                       sender: sender, subject: "", snippet: String(text.prefix(300)), time: time))
        }
        step = sqlite3_step(stmt)
    }
    if step != SQLITE_DONE { return failed() }
    return result
}

/// Both inboxes and Messages run together; refreshes share a four-second cache.
final class Codes {
    static let shared = Codes()
    private let queue = DispatchQueue(label: "codes")
    private var cached: [Int: (Date, [String: Any])] = [:]
    private var waiting: [Int: [([String: Any]) -> Void]] = [:]

    func search(_ minutes: Int, done: @escaping ([String: Any]) -> Void) {
        queue.async {
            if let (at, reply) = self.cached[minutes], Date().timeIntervalSince(at) < 4 { done(reply); return }
            if self.waiting[minutes] != nil { self.waiting[minutes]!.append(done); return }
            self.waiting[minutes] = [done]
            let since = Date().addingTimeInterval(-Double(minutes * 60)), group = DispatchGroup()
            let lock = NSLock()
            var results = [CodeSource]()
            let sources: [() -> CodeSource] = [
                { mailCodes("aianswer", email: "samin@aianswer.us", since: since) },
                { mailCodes("personal", email: "samin.yasar12@gmail.com", since: since) },
                { messageCodes(since: since) },
            ]
            for source in sources {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = source()
                    lock.lock(); results.append(result); lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: self.queue) {
                let hits = results.flatMap(\.hits).sorted { $0.time == $1.time ? $0.id < $1.id : $0.time > $1.time }
                let reply: [String: Any] = ["codes": hits.map(\.json), "sources": results.sorted { $0.source < $1.source }.map(\.json), "minutes": minutes]
                self.cached[minutes] = (Date(), reply)
                let calls = self.waiting.removeValue(forKey: minutes) ?? []
                calls.forEach { $0(reply) }
            }
        }
    }
}

func selftestCodes() {
    let cases: [(String, String?)] = [
        ("Your verification code is 2737", "2737"),
        ("G-482913 is your Google verification code", "482913"),
        ("Your Instagram code is 123 456", "123456"),
        ("Use 839201 to sign in. Don't share it.", "839201"),
        ("Black Friday: 40% off until 2026", nil),
        ("Order #558812 has shipped", nil),
        ("Your code: AB12CD", "AB12CD"),
        ("Verification code: 123-456", "123456"),
        ("Security: call +1 (212) 555-1234", nil),
        ("Security: $1234.56", nil),
        ("Sign in at https://example.com/839201", nil),
        ("Security office: CA 90210", nil),
        ("Verification on 2026-11-05 at 12:3456", nil),
        ("Code: invoice #558812", nil),
        ("Code: ABCDEF", nil),
        ("Code: 123456789", nil),
        ("Your code: 123456. Order #558812", "123456"),
        ("Order #558812. Your code: 654321", "654321"),
        ("Your code: 0123", "0123"),
        ("Your verification code is 2026", "2026"),
        ("1999 is your verification code", "1999"),
        ("Verification is available until 2026", nil),
    ]
    for (text, expected) in cases {
        let actual = extractCode(text)
        guard actual == expected else { fputs("FAIL: \(text): \(actual ?? "nil") != \(expected ?? "nil")\n", stderr); exit(1) }
    }
    guard codeText("Don&#39;t &amp; &#x41;&#66;&nbsp;") == "Don't & AB " else { fatalError("HTML entities") }
    let archive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "Your code: 2737"))
    guard messageCodeText(archive) == "Your code: 2737", messageCodeText(Data([0, 1, 2])).isEmpty else { fatalError("Messages archive") }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("codes-selftest-" + UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else { fatalError("Messages fixture") }
    let now = Date(), stamp = Int64(now.timeIntervalSinceReferenceDate * 1_000_000_000)
    let hex = archive.map { String(format: "%02x", $0) }.joined()
    let sql = """
    CREATE TABLE handle (id TEXT);
    CREATE TABLE message (text TEXT, attributedBody BLOB, date INTEGER, handle_id INTEGER, is_from_me INTEGER);
    INSERT INTO handle VALUES ('test sender');
    INSERT INTO message VALUES ('Your code: 839201', NULL, \(stamp), 1, 0);
    INSERT INTO message VALUES (NULL, X'\(hex)', \(stamp - 1000000000), 1, 0);
    INSERT INTO message VALUES ('Your code: 112233', NULL, \(stamp), 1, 1);
    INSERT INTO message VALUES ('Your code: 445566', NULL, 1, 1, 0);
    """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { fatalError("Messages fixture rows") }
    sqlite3_close(db)
    let messages = messageCodes(since: now.addingTimeInterval(-1800), path: path)
    guard messages.error == nil, messages.hits.map(\.code) == ["839201", "2737"], messages.hits.first?.sender == "test sender" else { fatalError("Messages query, cutoff or direction") }
    print("codes selftest: \(cases.count) extraction cases, HTML entities, Messages archives and SQLite cutoff/direction passed")
}
