# Muse Custom Connector (always-on, manual)

Muse runs on a Secure VM in Meta's cloud, so it cannot reach this Mac's socket. A tool server for Muse needs a public HTTPS URL. Photon's gateway serves it from the Mac through Tailscale Funnel, and a person connects it by hand in the Muse app. No API drives a user's Muse, so these steps are manual and cannot run in CI.

**Status (FT5): not verified.** The gateway and pairing are built and tested against a local client, but nobody has yet tried the connector from a real Muse account. Three things are unknown until the first live attempt: whether Muse accepts a bearer token or insists on OAuth 2.1, which MCP protocol version Muse speaks, and whether Muse's network policy allows the Funnel host. If Muse cannot reach or authenticate to the URL, this path is recorded as "not run" in `DECISIONS.md` and the supported path is Muse Code over local stdio ([muse-code.md](muse-code.md)). No other tunnel is used.

## Steps

1. **Turn Remote on in Photon.** Open Settings (⌘,) and tick "Enable Remote" in the Remote section. Photon starts its gateway on `127.0.0.1:47820`. Remote is off again each time Photon starts.
2. **Pair.** Click "Pair a phone". Photon mints a 32-byte token and shows it once, as a QR code, in the link `https://<your-mac>.<tailnet>.ts.net:10000/barestate/#t=<token>`. Scan it with a phone camera and copy the link. The token is the 64 hex characters after `#t=`; it is not stored on the Mac in that form (only its SHA-256 is), so it cannot be shown again. Close the window or pair again and the code is gone.
3. **Check the URL.** The connector's address is

   ```
   https://<your-mac>.<tailnet>.ts.net:10000/barestate/mcp
   ```

   where `<your-mac>.<tailnet>.ts.net` is this Mac's Tailscale name (`tailscale status --json`, field `Self.DNSName`, without the trailing dot). Funnel serves only ports 443, 8443 and 10000; Photon uses 10000.
4. **Ask Muse to create the connector.** In the Muse app, send:

   ```
   Create a Custom Connector for a new remote MCP server, then connect to it:
   Name: Photon
   Transport: remote streamable HTTP
   URL: https://<your-mac>.<tailnet>.ts.net:10000/barestate/mcp
   Auth: Bearer token
   ```

   Muse guides the rest and keeps the credential in its Secure Credentials Store.
5. **Paste the token only where Muse asks for it.** Muse shows a secure credential prompt for the bearer token. Paste the 64 hex characters there. Never put them in the chat, and never in a file in this repository.
6. **Approve on the Mac.** Reading and listing tabs works once connected. When Muse asks for control of a tab you are using, Photon shows an approval card on the Mac; nothing is granted until you click Allow. A sensitive action (a delete, a password field, a purchase) shows its own card every time. Muse's own prompt (Allow once, Always allow, Deny) is separate from Photon's card, and both must agree.
7. **Revoke.** Settings lists every paired device with its pairing date and when it was last seen. "Revoke" next to a device removes it: its token gets 401 on the next request and any open stream from it ends. Unticking "Enable Remote" stops the gateway for everyone. Removing the connector in the Muse app stops Muse from using it; pair again to get a new token.

"Enable Remote" also mounts the `/barestate` path of this Mac's Funnel address (port 10000). Turning it off or quitting Photon removes only that path; every other Funnel handler is left as it was.

## Security

The public URL controls a real browser. Every request, including `server/discover`, needs the bearer token. Keep Remote on only while you use it.
