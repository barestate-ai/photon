import Foundation

public struct SearchEngine: Equatable, Sendable {
  public let name: String
  /// `%s` stands for the query.
  public let template: String

  public static let all = [
    SearchEngine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"),
    SearchEngine(name: "Google", template: "https://www.google.com/search?q=%s"),
    SearchEngine(name: "Bing", template: "https://www.bing.com/search?q=%s"),
  ]
}

/// User preferences in `<data-dir>/settings.json`. Unknown keys are ignored and missing ones take
/// their default, so a later version can add fields without breaking an older file.
public struct Settings: Codable, Equatable, Sendable {
  public static let defaultSearchEngine = SearchEngine.all[0].template

  /// `%s` stands for the query.
  public var searchEngine = Settings.defaultSearchEngine

  public init() {}

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let engine = try values.decodeIfPresent(String.self, forKey: .searchEngine)
    if let engine, engine.contains("%s") { searchEngine = engine }
  }

  /// Only a missing file is written; one that exists but cannot be read gives defaults and is
  /// left alone, so a hand edit is never lost. `onError` gets a reason, never the file contents.
  public static func loadOrCreate(path: String, onError: (String) -> Void = { _ in }) -> Settings {
    guard FileManager.default.fileExists(atPath: path) else {
      let defaults = Settings()
      try? defaults.save(path: path)
      return defaults
    }
    guard let data = FileManager.default.contents(atPath: path) else {
      onError("unreadable")
      return Settings()
    }
    guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
      onError("invalid json")
      return Settings()
    }
    return settings
  }

  public func save(path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}
