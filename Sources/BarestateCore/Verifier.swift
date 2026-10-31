import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the model made of the before and after pictures.
public enum ModelVerdict: Sendable, Equatable {
  case success(String)
  case failure(String)
  case unavailable(String)

  /// The words the journal keeps in `model_verdict`.
  public var stored: String {
    switch self {
    case .success(let reason): "success: \(reason)"
    case .failure(let reason): "failure: \(reason)"
    case .unavailable(let reason): "unavailable: \(reason)"
    }
  }
}

/// The verified outcome of a write (architecture §5.7): the page's own read-back and the model's
/// reading of two screenshots must agree before anything is `confirmed`.
public enum Verifier {
  public static func decide(dom: DispatchOutcome, model: ModelVerdict) -> (
    state: ActionState, reason: String?
  ) {
    switch (dom.verified, model) {
    case (true, .success): return (.confirmed, nil)
    case (false, .failure(let why)):
      return (.failed, "read-back mismatch: \(dom.verdict) (model: \(why))")
    case (true, .failure(let why)):
      return (
        .outcomeUnknown,
        "disagree: page read-back says success, model says failure (\(why))"
      )
    case (false, .success(let why)):
      return (
        .outcomeUnknown,
        "disagree: page read-back says failure (\(dom.verdict)), model says success (\(why))"
      )
    case (true, .unavailable(let why)): return (.outcomeUnknown, "model unavailable: \(why)")
    case (false, .unavailable(let why)):
      return (.outcomeUnknown, "model unavailable: \(why); page read-back: \(dom.verdict)")
    }
  }

  private static let schema: JSON = [
    "type": "object",
    "properties": ["success": ["type": "boolean"], "reason": ["type": "string"]],
    "required": ["success", "reason"],
    "additionalProperties": false,
  ]

  private static let instructions =
    "You check whether a browser action worked, judging by the two screenshots only. You get "
    + "the action's intent, a screenshot taken just before it and one taken after it. The "
    + "pictures are the only evidence: the intent and the control's label say what was "
    + "attempted, not what happened, so never assume an effect from them, and a control that "
    + "sounds like it does nothing still has to show a change. success is true only when the "
    + "second picture visibly differs from the first in the way the intent implies. If the two "
    + "pictures look the same, or the change does not match the intent, success is false. In "
    + "reason, say what you saw. Answer with the JSON object only."

  public static func request(intent: String, before: Data, after: Data) -> ModelRequest {
    func image(_ jpeg: Data) -> JSON {
      [
        "type": "input_image",
        "image_url": .string("data:image/jpeg;base64," + jpeg.base64EncodedString()),
      ]
    }
    let words =
      "Intent: \(intent)\nThe first image is the page before the action, the second after it."
    return ModelRequest(
      instructions: instructions,
      input: [
        [
          "role": "user",
          "content": [
            ["type": "input_text", "text": .string(words)], image(before), image(after),
          ],
        ]
      ], schema: (name: "verdict", schema: schema), maxOutputTokens: 2000,
      effort: "minimal")
  }

  /// Reasoning tokens count against the cap, so a reply can end mid-sentence; that is no verdict,
  /// even if the cut happens to leave valid JSON.
  public static func verdict(response: ModelResponse) -> ModelVerdict {
    response.incompleteReason == nil
      ? verdict(text: response.text) : .unavailable("verdict cut off")
  }

  /// Only `{success: bool, reason: string}` is a verdict.
  public static func verdict(text: String) -> ModelVerdict {
    guard let object = JSON.parse(Data(text.utf8))?.object, object.count == 2,
      let success = object["success"]?.bool, let reason = object["reason"]?.string
    else { return .unavailable("malformed verdict") }
    return success ? .success(reason) : .failure(reason)
  }

  public static func verify(
    intent: String, before: Data, after: Data, client: ModelClient
  ) async -> ModelVerdict {
    do {
      let response = try await client.call(
        request(intent: intent, before: before, after: after), source: "verify")
      return verdict(response: response)
    } catch let error as ModelError {
      return .unavailable(error.code)
    } catch {
      return .unavailable("\(error)")
    }
  }

  /// Pictures wider than the model needs are scaled down; anything undecodable is sent as is.
  public static func fit(_ jpeg: Data, maxWidth: Int = 1280) -> Data {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > maxWidth
    else { return jpeg }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxWidth,
    ]
    let output = NSMutableData()
    guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let sink = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return jpeg }
    CGImageDestinationAddImage(
      sink, small, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    return CGImageDestinationFinalize(sink) ? output as Data : jpeg
  }

  /// A JPEG of the viewport as displayed, no `clip` (see `PreviewCapture.screenshot`).
  public static func capture(_ transport: any CDPTransport) async throws -> Data {
    let reply = try await transport.send(
      "Page.captureScreenshot", ["format": "jpeg", "quality": 70, "fromSurface": true])
    guard let encoded = reply["data"]?.string, let jpeg = Data(base64Encoded: encoded) else {
      throw CDPError.remote(code: -32000, message: "no screenshot of the viewport")
    }
    return fit(jpeg)
  }
}
