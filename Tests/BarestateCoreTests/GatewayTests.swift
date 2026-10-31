import BarestateCore
import Foundation
import Testing

struct GatewayTests {
  private func head(_ text: String) -> HTTPHead.Parsed {
    HTTPHead.parse(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
  }

  private func request(_ lines: String...) -> HTTPHead {
    guard case .head(let head) = self.head(lines.joined(separator: "\n") + "\n\n") else {
      fatalError("not a head: \(lines)")
    }
    return head
  }

  @Test func parsesTheRequestLineHeadersAndLength() throws {
    let text = "POST /mcp?x=1 HTTP/1.1\nHost: 127.0.0.1:47820\nContent-Length: 12\n\nrest"
    guard case .head(let parsed) = head(text) else {
      Issue.record("no head")
      return
    }
    #expect(parsed.method == "POST" && parsed.path == "/mcp")
    #expect(parsed.headers["host"] == "127.0.0.1:47820" && parsed.contentLength == 12)
    #expect(parsed.length == text.replacingOccurrences(of: "\n", with: "\r\n").utf8.count - 4)
  }

  @Test func waitsForTheBlankLineAndBoundsTheHead() {
    #expect(head("GET / HTTP/1.1\nHost: a\n") == .incomplete)
    let huge = "GET / HTTP/1.1\nX: " + String(repeating: "a", count: HTTPHead.maxHead) + "\n\n"
    #expect(head(huge) == .invalid(status: 431))
    #expect(
      HTTPHead.parse(Data(repeating: 0x61, count: HTTPHead.maxHead + 1)) == .invalid(status: 431))
  }

  @Test func refusesWhatItCannotFrameSafely() {
    #expect(head("GET / HTTP/2\nHost: a\n\n") == .invalid(status: 400))
    #expect(head("GET http://a/ HTTP/1.1\nHost: a\n\n") == .invalid(status: 400))
    #expect(head("GET / HTTP/1.1\nHost a\n\n") == .invalid(status: 400))
    #expect(head("GET / HTTP/1.1\nHost : a\n\n") == .invalid(status: 400))
    #expect(head("GET / HTTP/1.1\nHost: a\nHost: b\n\n") == .invalid(status: 400))
    #expect(head("POST / HTTP/1.1\nContent-Length: -1\n\n") == .invalid(status: 400))
    #expect(
      head("POST / HTTP/1.1\nContent-Length: 1\nContent-Length: 1\n\n") == .invalid(status: 400))
    #expect(head("POST / HTTP/1.1\nTransfer-Encoding: chunked\n\n") == .invalid(status: 501))
  }

  @Test func onlyTheNamedHostsAreServed() {
    let policy = GatewayPolicy(port: 47820, publicHost: "pub.example.ts.net:10000")
    func status(_ host: String?, origin: String? = nil) -> Int? {
      var lines = ["POST /mcp HTTP/1.1"]
      if let host { lines.append("Host: \(host)") }
      if let origin { lines.append("Origin: \(origin)") }
      return policy.rejects(request(lines.joined(separator: "\n")))
    }
    for host in [
      "127.0.0.1:47820", "localhost:47820", "LOCALHOST:47820", "pub.example.ts.net:10000",
    ] {
      #expect(status(host) == nil, "\(host)")
    }
    for host in ["evil.example", "127.0.0.1:9999", "127.0.0.1", "pub.example.ts.net", "", nil] {
      #expect(status(host) == 403, "\(host ?? "none")")
    }
  }

  @Test func anOriginMustNameAnAllowedHost() {
    let policy = GatewayPolicy(port: 47820, publicHost: "pub.example.ts.net:10000")
    func status(_ origin: String) -> Int? {
      policy.rejects(request("POST /mcp HTTP/1.1", "Host: 127.0.0.1:47820", "Origin: \(origin)"))
    }
    #expect(status("http://127.0.0.1:47820") == nil)
    #expect(status("https://pub.example.ts.net:10000") == nil)
    for origin in [
      "https://evil.example", "null", "https://pub.example.ts.net", "ftp://127.0.0.1:47820",
    ] {
      #expect(status(origin) == 403, "\(origin)")
    }
  }

  @Test func withoutAPublicHostOnlyLoopbackIsServed() {
    let policy = GatewayPolicy(port: 47820, publicHost: nil)
    #expect(policy.rejects(request("GET / HTTP/1.1", "Host: pub.example.ts.net:10000")) == 403)
    #expect(policy.rejects(request("GET / HTTP/1.1", "Host: localhost:47820")) == nil)
  }

  @Test func bearerTokensAreReadOnlyFromTheBearerScheme() {
    func token(_ header: String?) -> String? {
      GatewayPolicy.bearer(
        request("GET / HTTP/1.1", header.map { "Authorization: \($0)" } ?? "X: y"))
    }
    #expect(token("Bearer abc") == "abc")
    #expect(token("bearer abc") == "abc")
    #expect(token("Basic YTpi") == nil)
    #expect(token("Bearer") == nil)
    #expect(token("Bearer ") == nil)
    #expect(token(nil) == nil)
  }

  @Test func everyApiAndMcpRouteNeedsAToken() {
    #expect(GatewayRoute(path: "/mcp") == .mcp && GatewayRoute(path: "/mcp").needsToken)
    #expect(GatewayRoute(path: "/api/events") == .events)
    #expect(GatewayRoute(path: "/api/task") == .api("task"))
    #expect(GatewayRoute(path: "/api/whatever").needsToken)
    #expect(GatewayRoute(path: "/api/").needsToken)
    #expect(GatewayRoute(path: "/") == .phone && !GatewayRoute(path: "/").needsToken)
    #expect(GatewayRoute(path: "/__health") == .health)
    #expect(GatewayRoute(path: "/tabs") == .notFound && !GatewayRoute(path: "/tabs").needsToken)
  }

  @Test func theLimiterAllowsThirtyInAnySecondPerKeyAndRecovers() {
    var limiter = SlidingWindowLimiter(limit: 30, window: 1)
    var allowed = 0
    for tick in 0..<100 where limiter.allow("a", at: Double(tick) / 1000) { allowed += 1 }
    #expect(allowed == 30)
    let other = limiter.allow("b", at: 0.1)
    let stillFull = limiter.allow("a", at: 0.999)
    let recovered = limiter.allow("a", at: 1.5)
    #expect(other && !stillFull && recovered)
  }
}
