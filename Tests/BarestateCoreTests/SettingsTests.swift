import BarestateCore
import Foundation
import Testing

struct SettingsTests {
  private func tempPath() -> String {
    NSTemporaryDirectory() + "bs-settings-\(UUID().uuidString).json"
  }

  @Test func aMissingFileIsCreatedWithDefaults() throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let settings = Settings.loadOrCreate(path: path)
    #expect(settings.searchEngine == "https://duckduckgo.com/?q=%s")
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(Settings.loadOrCreate(path: path) == settings)
  }

  @Test func savedValuesSurviveAReload() throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    var settings = Settings()
    settings.searchEngine = "https://example.test/?q=%s"
    try settings.save(path: path)
    #expect(Settings.loadOrCreate(path: path).searchEngine == "https://example.test/?q=%s")
  }

  @Test func unknownAndMissingKeysAreTolerated() throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try Data(#"{"futureKey": 3}"#.utf8).write(to: URL(fileURLWithPath: path))
    #expect(Settings.loadOrCreate(path: path) == Settings())
  }

  @Test func aCorruptFileGivesDefaultsAndIsLeftAlone() throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
    var reasons: [String] = []
    #expect(Settings.loadOrCreate(path: path) { reasons.append($0) } == Settings())
    #expect(reasons == ["invalid json"])
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "not json")
  }

  @Test func anUnreadablePathIsNotReplacedWithDefaults() throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    var reasons: [String] = []
    #expect(Settings.loadOrCreate(path: path) { reasons.append($0) } == Settings())
    #expect(reasons == ["unreadable"])
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }

  @Test func aFileWithRetiredLayoutKeysStillLoadsAndDropsThem() throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try Data(
      #"{"searchEngine": "https://www.bing.com/search?q=%s", "tabLayout": "vertical", "sidebarPinned": false}"#
        .utf8
    ).write(to: URL(fileURLWithPath: path))
    let loaded = Settings.loadOrCreate(path: path)
    #expect(loaded.searchEngine == "https://www.bing.com/search?q=%s")
    try loaded.save(path: path)
    let saved = try String(contentsOfFile: path, encoding: .utf8)
    #expect(!saved.contains("tabLayout") && !saved.contains("sidebarPinned"))
  }

  @Test func everyListedSearchEngineHasAQueryPlaceholder() {
    #expect(SearchEngine.all.first?.template == Settings.defaultSearchEngine)
    #expect(SearchEngine.all.allSatisfy { $0.template.contains("%s") })
  }

  @Test func aSearchTemplateWithoutAPlaceholderFallsBackToTheDefault() throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try Data(#"{"searchEngine": "https://example.test/"}"#.utf8).write(
      to: URL(fileURLWithPath: path))
    #expect(Settings.loadOrCreate(path: path).searchEngine == Settings().searchEngine)
  }
}
