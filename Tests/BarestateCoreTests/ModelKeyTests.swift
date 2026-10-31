import BarestateCore
import Testing

struct ModelKeyTests {
  private func resolve(
    environment: [String: String] = [:], envFile: String? = nil, keychain: String? = nil
  ) -> ModelKey.Found? {
    ModelKey.resolve(environment: environment, envFile: envFile, keychain: { keychain })
  }

  @Test func theEnvironmentWinsOverTheFileAndTheKeychain() {
    let found = resolve(
      environment: ["MODEL_API_KEY": "from-env"], envFile: "MODEL_API_KEY=from-file\n",
      keychain: "from-keychain")
    #expect(found?.source == .environment)
    #expect(found?.value == "from-env")
  }

  @Test func theEnvFileWinsOverTheKeychain() {
    let found = resolve(envFile: "A=1\nexport MODEL_API_KEY=\"from-file\"\n", keychain: "k")
    #expect(found?.source == .envFile)
    #expect(found?.value == "from-file")
  }

  @Test func theKeychainIsTheLastResort() {
    let found = resolve(keychain: "from-keychain")
    #expect(found?.source == .keychain)
    #expect(found?.value == "from-keychain")
  }

  @Test func nothingAnywhereIsNoKey() {
    #expect(resolve() == nil)
    #expect(resolve(keychain: "  ") == nil)
  }

  @Test func emptyOrCommentedValuesDoNotCount() {
    #expect(resolve(environment: ["MODEL_API_KEY": "  "]) == nil)
    #expect(resolve(envFile: "MODEL_API_KEY=\n") == nil)
    #expect(resolve(envFile: "MODEL_API_KEY=''\n") == nil)
    #expect(resolve(envFile: "# MODEL_API_KEY=abc\n") == nil)
    #expect(resolve(envFile: "OTHER_MODEL_API_KEY=abc\n") == nil)
  }

  @Test func theFoundKeyPrintsItsSourceNotItsValue() {
    let found = resolve(environment: ["MODEL_API_KEY": "secret-value"])
    #expect(!"\(found!)".contains("secret-value"))
    #expect(!String(reflecting: found!).contains("secret-value"))
    #expect("\(found!)".contains("environment"))
  }

  @Test func anotherVariableResolvesTheSameWay() {
    let found = ModelKey.resolve(
      variable: "BASETEN_API_KEY", environment: ["BASETEN_API_KEY": "b"], envFile: nil)
    #expect(found?.value == "b")
    #expect(ModelKey.resolve(variable: "BASETEN_API_KEY", environment: [:], envFile: nil) == nil)
  }
}
