# Muse Code with Photon (local, stdio)

Muse Code starts `barestate-mcp` as a stdio MCP server. It forwards each request to the Photon app on this Mac, so Photon must be running first. Muse Code reads its config once per process, so start Photon, then Muse Code.

## Where the server is

The release app carries it: `/Applications/Photon.app/Contents/MacOS/barestate-mcp` (use the path of wherever you put `Photon.app`). Use that absolute path as `command` below.

Building from source instead: `swift build -c release` writes `.build/release/barestate-mcp`, and `make bundle` copies it into `.build/Photon.app/Contents/MacOS/`.

## Add it to Muse Code

Put this in `~/.config/muse/settings.json` (or `$XDG_CONFIG_HOME/muse/settings.json`). If the file already has other settings, add only the `barestate` entry under `mcpServers`. Replace the `command` path with the one for your install.

```json
{
  "schema_version": 1,
  "mcpServers": {
    "barestate": {
      "type": "stdio",
      "command": "/Applications/Photon.app/Contents/MacOS/barestate-mcp",
      "args": ["--stdio"],
      "env": {},
      "required": false,
      "startup_timeout_sec": 30,
      "tool_timeout_sec": 120
    }
  }
}
```

Use only these key names. A file that mixes the older spellings (`mcp_servers`, `transport`, `mode`) with these turns MCP off for the whole session.

`/mcp` in Muse Code then shows `barestate` as `connected`, and the tools appear as `mcp__barestate__tabs`, `mcp__barestate__observe`, and so on.

## Which socket

`barestate-mcp` connects to Photon's `app.sock`, chosen in this order:

1. `--socket <path>` in `args`
2. the `BARESTATE_SOCKET` environment variable (set it under `env`; Muse Code clears the rest of the environment)
3. `~/Library/Application Support/Barestate/browser/app.sock`, the default data directory

Use `"args": ["--stdio", "--socket", "/path/to/data-dir/app.sock"]` when Photon runs with `--data-dir`.

## Check it by hand

With Photon running:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  | /Applications/Photon.app/Contents/MacOS/barestate-mcp --stdio
```

One JSON line comes back with `serverInfo.name` `barestate-mcp`, and the process exits when stdin closes. stdout carries protocol messages only; diagnostics go to stderr. If Photon is not running, each request gets a JSON-RPC error saying so.

If Muse Code's `framing: auto` probe fails, set `"framing": "line_delimited_json"` on the server entry.

## What the tools do

| Tool | Does |
|---|---|
| `tabs`, `observe`, `extract`, `action_status` | Read only. |
| `open_tab` | Opens a web page in a new tab that your session controls. |
| `request_control` | Asks for another tab. The person approves on the Mac; nothing is granted until they do. |
| `act` | Click, type, select, press, scroll or navigate. `clientActionId` is required; repeating one returns the same action. A sensitive target comes back `quoted` until the person allows it on the Mac; follow it with `action_status`. |
| `handoff` | Gives a tab back to the person. |

A failed tool call is a result with `isError: true`, not a protocol error.

## Not verified

Muse Code is not installed on the build machine, so the `connected` state in `/mcp` is not checked here. The handshake, tool list and calls are tested against the real app by `e2e/test_mcp.py`.
