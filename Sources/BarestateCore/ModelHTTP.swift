import Foundation

/// Sends one request. With `onLine`, the body is read as a stream and every line is passed on as
/// it arrives. The default talks to the network; tests swap it only to inject faults.
public typealias ModelTransport =
  @Sendable (URLRequest, (@Sendable (String) -> Void)?) async throws -> (Data, HTTPURLResponse)

/// The real network.
public let liveModelTransport: ModelTransport = { request, onLine in
  let session = URLSession.shared
  guard let onLine else {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, http)
  }
  let (bytes, response) = try await session.bytes(for: request)
  guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
  var data = Data()
  for try await line in bytes.lines {
    onLine(line)
    data.append(Data((line + "\n").utf8))
  }
  return (data, http)
}

struct ModelHTTP: Sendable {
  var transport: ModelTransport
  var timeout: TimeInterval

  /// The body of a 2xx reply and its `x-request-id`; every other outcome is a typed error.
  func post(
    _ url: URL, key: String, body: JSON, onLine: (@Sendable (String) -> Void)? = nil
  ) async throws -> (Data, String?) {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if onLine != nil { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
    request.httpBody = Data(body.serialized().utf8)
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport(request, onLine)
    } catch let error as URLError {
      switch error.code {
      case .timedOut: throw ModelError.timeout
      // A stopped run cancels its call; that is not the provider being down.
      case .cancelled: throw ModelError.refused("cancelled")
      default: throw ModelError.unreachable
      }
    }
    switch response.statusCode {
    case 200..<300:
      return (data, response.value(forHTTPHeaderField: "x-request-id"))
    case 429, 500...:
      throw ModelError.server(status: response.statusCode)
    default:
      let echoed = JSON.parse(data)?["error"]?["message"]?.string ?? ""
      // Redact before cutting, so a key straddling the limit is never left as a prefix.
      let message = echoed.replacingOccurrences(of: key, with: "[redacted]")
      throw ModelError.rejected(status: response.statusCode, message: String(message.prefix(200)))
    }
  }

  static func json(_ data: Data) throws -> JSON {
    guard let json = JSON.parse(data), json.object != nil else {
      throw ModelError.malformed("body is not JSON")
    }
    return json
  }
}
