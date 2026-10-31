import BarestateCore
import Testing

struct LaunchOptionsTests {
  private let home = "/Users/someone"

  @Test func defaultsToTheApplicationSupportDirectory() throws {
    let options = try LaunchOptions.parse([], home: home)
    #expect(options.dataDir.root == "/Users/someone/Library/Application Support/Barestate/browser")
    #expect(options.testHooks == false)
    #expect(options.url == nil)
  }

  @Test func parsesSpaceAndEqualsForms() throws {
    let spaced = try LaunchOptions.parse(
      ["--data-dir", "/tmp/bs-a", "--test-hooks", "--url", "http://127.0.0.1:47810/"], home: home)
    #expect(spaced.dataDir.root == "/tmp/bs-a")
    #expect(spaced.testHooks)
    #expect(spaced.url == "http://127.0.0.1:47810/")
    let equals = try LaunchOptions.parse(["--data-dir=/tmp/bs-b", "--url=about:blank"], home: home)
    #expect(equals.dataDir.root == "/tmp/bs-b")
    #expect(equals.url == "about:blank")
  }

  @Test func ignoresArgumentsItDoesNotOwn() throws {
    let options = try LaunchOptions.parse(["-ApplePersistenceIgnoreState", "YES"], home: home)
    #expect(options.testHooks == false)
  }

  @Test func missingValueIsAnError() {
    #expect(throws: LaunchOptions.Failure.missingValue("--data-dir")) {
      try LaunchOptions.parse(["--data-dir"], home: home)
    }
  }

  @Test func dataDirLayoutNamesEveryFile() throws {
    let dir = try LaunchOptions.parse(["--data-dir", "/tmp/bs-x"], home: home).dataDir
    #expect(dir.profile == "/tmp/bs-x/profile")
    #expect(dir.logs == "/tmp/bs-x/logs")
    #expect(dir.sqlite == "/tmp/bs-x/barestate.sqlite")
    #expect(dir.socket == "/tmp/bs-x/app.sock")
    #expect(dir.pid == "/tmp/bs-x/app.pid")
    #expect(dir.tmp == "/tmp/bs-x/tmp")
  }

  @Test func rejectsADataDirWhoseSocketPathCannotFit() {
    let long = "/tmp/" + String(repeating: "d", count: 100)
    #expect(throws: LaunchOptions.Failure.socketPathTooLong(long + "/app.sock")) {
      try LaunchOptions.parse(["--data-dir", long], home: home)
    }
  }
}
