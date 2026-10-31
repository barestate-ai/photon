import Foundation

/// Reads page content from an isolated world: the extractor sees the page's DOM but shares no
/// globals with its scripts, in either direction.
public enum Extractor {
  public enum Format: String, Sendable {
    case text, markdown
  }

  public static let worldName = "barestate"

  public static func extract(transport: any CDPTransport, format: Format, ref: Int? = nil)
    async throws -> String
  {
    if let ref {
      return try await callOnNode(
        transport, ref: ref, function: script, arguments: [.string(format.rawValue)]
      ).string ?? ""
    }
    let context = try await isolatedContext(transport)
    let reply = try await transport.send(
      "Runtime.evaluate",
      [
        "contextId": .number(Double(context)), "returnByValue": true,
        "expression": .string(
          "(\(script)).call(document.body, \(JSON.string(format.rawValue).serialized()))"),
      ])
    return try value(of: reply).string ?? ""
  }

  /// Resolves `ref` in the isolated world and hands `body` the node's object id, released on every
  /// path.
  static func withNode<T>(
    _ transport: any CDPTransport, ref: Int, isolation: isolated (any Actor)? = #isolation,
    _ body: (String) async throws -> T
  ) async throws -> T {
    let context = try await isolatedContext(transport)
    let node = try await transport.send(
      "DOM.resolveNode",
      ["backendNodeId": .number(Double(ref)), "executionContextId": .number(Double(context))])
    guard let objectId = node["object"]?["objectId"]?.string else {
      throw CDPError.remote(code: -32000, message: "ref \(ref) does not resolve to a node")
    }
    return try await holding(objectId, transport, body)
  }

  /// Hands `body` the object id and releases it on every path.
  static func holding<T>(
    _ objectId: String, _ transport: any CDPTransport,
    isolation: isolated (any Actor)? = #isolation, _ body: (String) async throws -> T
  ) async throws -> T {
    let result: T
    do {
      result = try await body(objectId)
    } catch {
      _ = try? await transport.send("Runtime.releaseObject", ["objectId": .string(objectId)])
      throw error
    }
    _ = try? await transport.send("Runtime.releaseObject", ["objectId": .string(objectId)])
    return result
  }

  /// The `Runtime.callFunctionOn` request that runs `function` with `this` bound to the object.
  static func call(objectId: String, function: String, arguments: [JSON] = []) -> (
    method: String, params: JSON
  ) {
    (
      "Runtime.callFunctionOn",
      [
        "objectId": .string(objectId), "functionDeclaration": .string(function),
        "arguments": .array(arguments.map { ["value": $0] }), "returnByValue": true,
      ]
    )
  }

  /// Runs `function` with `this` bound to the node behind `ref`, in the isolated world, and
  /// returns its value.
  static func callOnNode(
    _ transport: any CDPTransport, ref: Int, function: String, arguments: [JSON] = []
  ) async throws -> JSON {
    try await withNode(transport, ref: ref) { objectId in
      let request = call(objectId: objectId, function: function, arguments: arguments)
      return try value(of: try await transport.send(request.method, request.params))
    }
  }

  /// Test hook support: evaluates in the same world `extract` uses.
  public static func evaluateInIsolatedWorld(transport: any CDPTransport, expression: String)
    async throws -> JSON
  {
    let context = try await isolatedContext(transport)
    return try value(
      of: await transport.send(
        "Runtime.evaluate",
        [
          "contextId": .number(Double(context)), "expression": .string(expression),
          "returnByValue": true,
        ]))
  }

  /// Asking again for the same name and frame returns the same world, so nothing accumulates.
  static func isolatedContext(_ transport: any CDPTransport) async throws -> Int {
    let tree = try await transport.send("Page.getFrameTree", [:])
    guard let frameId = tree["frameTree"]?["frame"]?["id"]?.string else {
      throw CDPError.remote(code: -32000, message: "the tab has no main frame")
    }
    let world = try await transport.send(
      "Page.createIsolatedWorld", ["frameId": .string(frameId), "worldName": .string(worldName)])
    guard let context = world["executionContextId"]?.int else {
      throw CDPError.remote(code: -32000, message: "no isolated execution context")
    }
    return context
  }

  static func value(of reply: JSON) throws -> JSON {
    if let details = reply["exceptionDetails"] {
      let text =
        details["exception"]?["description"]?.string ?? details["text"]?.string ?? "script error"
      throw CDPError.remote(code: -32000, message: text)
    }
    return reply["result"]?["value"] ?? .null
  }

  /// Runs with `this` as the root and the format as its argument. Declares no globals.
  public static let script = #"""
    function (format) {
      const markdown = format === "markdown";
      const skipped = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "SVG"]);
      const blocks = new Set(["P", "DIV", "SECTION", "ARTICLE", "MAIN", "HEADER", "FOOTER", "NAV",
        "ASIDE", "UL", "OL", "TABLE", "TR", "H1", "H2", "H3", "H4", "H5", "H6", "BLOCKQUOTE", "PRE",
        "FORM", "FIGURE", "DL", "HR"]);
      const lines = new Set(["LI", "DT", "DD", "BR"]);
      const wrap = (mark, inner) => inner.trim() ? mark + inner.trim() + mark : "";
      const visit = (node) => {
        if (node.nodeType === Node.TEXT_NODE) return node.nodeValue.replace(/\s+/g, " ");
        if (node.nodeType !== Node.ELEMENT_NODE || skipped.has(node.tagName.toUpperCase())) return "";
        const style = getComputedStyle(node);
        if (style.display === "none" || style.visibility === "hidden") return "";
        const tag = node.tagName.toUpperCase();
        if (tag === "BR") return "\n";
        if (tag === "IMG") {
          return markdown && node.alt ? "![" + node.alt + "](" + node.src + ")" : node.alt || "";
        }
        let text = Array.from(node.childNodes, visit).join("");
        const heading = /^H([1-6])$/.exec(tag);
        if (markdown) {
          if (heading) text = "#".repeat(Number(heading[1])) + " " + text.trim();
          else if (tag === "A" && node.href && text.trim()) text = "[" + text.trim() + "](" + node.href + ")";
          else if (tag === "LI") text = "- " + text.trim();
          else if (tag === "STRONG" || tag === "B") text = wrap("**", text);
          else if (tag === "EM" || tag === "I") text = wrap("_", text);
          else if (tag === "CODE") text = wrap("`", text);
        }
        if (blocks.has(tag)) return "\n\n" + text.trim() + "\n\n";
        return lines.has(tag) ? "\n" + text.trim() + "\n" : text;
      };
      return visit(this).replace(/[ \t]*\n[ \t]*/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
    }
    """#
}
