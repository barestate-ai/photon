import BarestateCore
import Foundation
import Testing

struct LogFileTests {
  private func scratch() -> String {
    let dir = NSTemporaryDirectory() + "bs-logfile-\(UUID().uuidString.prefix(8))"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  private func lines(_ path: String) -> [String] {
    ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(
      String.init)
  }

  @Test func writesOneLineWithTimeLevelCategoryAndMessage() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let log = try #require(LogFile(path: dir + "/photon.log"))
    log.append(level: "info", category: "tabs", message: "create tab=t1")
    let line = try #require(lines(dir + "/photon.log").first)
    #expect(
      line.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z info tabs create tab=t1$"#,
        options: .regularExpression) != nil, "\(line)")
  }

  @Test func newlinesInAMessageCannotForgeALine() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let log = try #require(LogFile(path: dir + "/photon.log"))
    log.append(level: "info", category: "tabs", message: "a\nb\r\nc")
    #expect(lines(dir + "/photon.log").count == 1)
  }

  @Test func aHugeMessageIsTruncatedToOneBoundedLine() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let log = try #require(LogFile(path: dir + "/photon.log"))
    log.append(level: "info", category: "tabs", message: String(repeating: "x", count: 100_000))
    let written = lines(dir + "/photon.log")
    #expect(written.count == 1)
    #expect(written[0].count < 8_300)
  }

  @Test func rotatesToOneOlderFileAtTheCap() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let log = try #require(LogFile(path: dir + "/photon.log", cap: 400))
    for index in 0..<40 { log.append(level: "info", category: "store", message: "event \(index)") }
    let current = lines(dir + "/photon.log")
    let older = lines(dir + "/photon.log.1")
    #expect(!older.isEmpty)
    #expect(current.last?.hasSuffix("event 39") == true)
    #expect(FileManager.default.fileExists(atPath: dir + "/photon.log.2") == false)
    let size =
      (try FileManager.default.attributesOfItem(atPath: dir + "/photon.log"))[.size] as! Int
    #expect(size <= 400)
  }

  @Test func keepsDescriptorStableAcrossRotationAndAppendsToExistingFile() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let first = try #require(LogFile(path: dir + "/photon.log", cap: 400))
    first.append(level: "info", category: "quit", message: "one")
    let descriptor = first.descriptor
    for index in 0..<40 { first.append(level: "info", category: "quit", message: "fill \(index)") }
    #expect(first.descriptor == descriptor)
    let second = try #require(LogFile(path: dir + "/photon.log", cap: 400))
    second.append(level: "info", category: "quit", message: "again")
    #expect(lines(dir + "/photon.log").last?.hasSuffix("again") == true)
  }

  @Test func aSecondWriterFollowsTheFileWhenTheFirstRotatesIt() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let app = try #require(LogFile(path: dir + "/photon.log", cap: 400))
    let gateway = try #require(LogFile(path: dir + "/photon.log", cap: .max))
    gateway.append(level: "info", category: "remote", message: "before")
    for index in 0..<40 { app.append(level: "info", category: "store", message: "fill \(index)") }
    #expect(!lines(dir + "/photon.log.1").isEmpty)
    gateway.append(level: "info", category: "remote", message: "after")
    #expect(lines(dir + "/photon.log").contains { $0.hasSuffix("after") })
    #expect(!lines(dir + "/photon.log.1").contains { $0.hasSuffix("after") })
  }

  @Test func aDeletedLogIsCreatedAgainByTheNextLine() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let log = try #require(LogFile(path: dir + "/photon.log"))
    log.append(level: "info", category: "store", message: "one")
    try FileManager.default.removeItem(atPath: dir + "/photon.log")
    log.append(level: "info", category: "store", message: "two")
    #expect(lines(dir + "/photon.log").map { $0.hasSuffix("two") } == [true])
  }

  @Test func originKeepsSchemeAndHostOnly() {
    #expect(LogFile.origin("http://127.0.0.1:47810/form.html?q=secret-query") == "http://127.0.0.1")
    #expect(LogFile.origin("https://user:pw@example.com/a/b#frag") == "https://example.com")
    #expect(LogFile.origin("about:blank") == "about")
    #expect(LogFile.origin("file:///Users/x/secret.html") == "file")
    #expect(LogFile.origin("javascript:alert(1)") == "javascript")
    #expect(LogFile.origin("not a url") == "invalid")
    #expect(LogFile.origin("") == "invalid")
  }
}
