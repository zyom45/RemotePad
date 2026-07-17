# RemotePad

RemotePad is an iPad-first remote development client for a continuously running Mac.

The initial implementation starts with the shared protocol layer used by the future iPad app and Mac Agent.

## Current Implementation

- Swift Package scaffold
- `RemotePadProtocol` library
- RPAD frame encoder / decoder
- Streaming frame decoder
- JSON header helpers
- Mac development agent with loopback-only TCP listener
- Agent-managed PTY terminal create / attach / close
- HTTP BrowserProxy spike for Mac localhost fetches
- TCP BrowserProxy stream for Mac localhost tunnels
- Development local listener that forwards `127.0.0.1:<listen>` to Mac localhost over BrowserProxy stream
- iPad SwiftUI app scaffold with WebView and local listener wiring
- iPad terminal workspace with SwiftTerm rendering, authenticated connect, keyboard input, output display, interrupt, resize, and clear
- Development CLI client
- Mac SwiftUI pairing approver
- Pairing store tests
- Unit tests for frame, control, terminal, and browser proxy messages

Current authentication uses a signed nonce challenge. The client sends a Curve25519 signing public key in `ClientHello`, signs the auth transcript, and the agent verifies `AuthProof.signature`. The iPad app and development client can submit signed pairing requests. The Mac can approve requests through the SwiftUI pairing approver or explicit development CLI commands. The agent is loopback-only by default; E2E-protected LAN and Bonjour exposure require the explicit `--lan` gate.

Authenticated sessions use an application-layer E2E channel: ephemeral X25519 key agreement, signed handshake transcripts, HKDF-SHA256 directional keys, and ChaCha20-Poly1305 encrypted frames with replay counters. The relay or local network transport cannot read or modify Terminal and BrowserProxy traffic.

To pair the iPad app:

1. Start `remotepad-agent`.
2. In the iPad app, enter the agent host/port and tap `Request Pairing`.
3. Approve the pending request on the Mac:

```sh
swift run remotepad-agent --list-pairing-requests
swift run remotepad-agent --approve-pairing <device-id>
```

To trust a development client directly:

```sh
swift run remotepad-dev-client --identity
swift run remotepad-agent --trust-device <device-id> <public-key-base64>
```

To verify the pairing protocol from the CLI:

```sh
swift run remotepad-dev-client --pair <agent-port> "RemotePad CLI Pairing Test"
swift run remotepad-agent --list-pairing-requests
swift run remotepad-agent --approve-pairing <device-id>
swift run remotepad-dev-client --pair-status <agent-port>
```

To inspect or revoke trusted devices:

```sh
swift run remotepad-agent --list-trusted
swift run remotepad-agent --revoke-device <device-id>
```

## Test

```sh
swift test
```

Run the local integration check:

```sh
scripts/check-local-integration.sh
```

The integration check starts a loopback-only agent, submits and approves a pairing request, verifies approved pairing status, creates an authenticated terminal, checks for `__REMOTEPAD_READY__`, revokes the verification device, and runs `swift test`.

Run the browser proxy check:

```sh
scripts/check-browser-proxy.sh
```

The browser proxy check starts a local fixture server and verifies HTTP, chunked responses, SSE, and WebSocket upgrade through the RemotePad browser stream and local proxy path.

Useful agent environment variables:

- `REMOTEPAD_OPEN_PAIRING_APPROVER=0`: disable automatic pairing approver launch.
- `REMOTEPAD_AGENT_PORT=<port>`: bind the agent to a fixed local port for tests.

## iPad App

Generate or refresh the Xcode project:

```sh
xcodegen generate
```

Open `RemotePad.xcodeproj` and run the `RemotePad` iPad app target.

The app can submit a pairing request to the Mac agent. Approve it on the Mac before connecting:

```sh
swift run remotepad-agent --list-pairing-requests
swift run remotepad-agent --approve-pairing <ipad-device-id>
```

For simulator development with the current loopback-only agent, use `127.0.0.1` as the agent host. Real iPad device testing requires the later LAN-safe pairing/agent exposure work.

For a real iPad on the same trusted local network, start the E2E-only LAN listener explicitly:

```sh
swift run remotepad-agent --lan
```

The agent prints one or more `connect: <Mac-IP>:53241` addresses. Enter that address and port in the iPad app, request pairing, approve it on the Mac, then connect the Terminal or Browser workspace. LAN and Bonjour exposure remain disabled unless `--lan` or `REMOTEPAD_ENABLE_LAN=1` is supplied.

## Local Handshake Check

Start the development agent:

```sh
swift run remotepad-agent
```

In another terminal, pass the printed agent port to the development client:

```sh
swift run remotepad-dev-client <port>
```

The client should print `received server.hello`, `received auth.result`, `received terminal.created`, `received terminal.list.result`, and `received terminal.output`.

To verify reconnecting to an existing terminal, run the dev client again:

```sh
swift run remotepad-dev-client <port> --attach-first
```

The client should print `received terminal.attached` and terminal output containing `__REMOTEPAD_ATTACHED__`.
The attach response also replays the terminal's recent output buffer before new output arrives.

To verify closing a terminal:

```sh
swift run remotepad-dev-client <port> --close-after-ready
```

The client should print `received terminal.closed`. A later `--attach-first` run should show `terminals: 0`.

To verify the HTTP BrowserProxy path, start a local HTTP server:

```sh
python3 -m http.server 18080 --bind 127.0.0.1
```

Then ask the agent to fetch through the browser proxy:

```sh
swift run remotepad-dev-client <agent-port> --browser-get 18080 /README.md
```

The client should print `received browser.response` with status `200`.

To verify the TCP BrowserProxy stream path against the same local server:

```sh
swift run remotepad-dev-client <agent-port> --browser-stream-get 18080 /README.md
```

The client should print `received browser.stream.data` with raw HTTP response bytes, followed by `received browser.stream.close`.

To verify the local listener path:

```sh
swift run remotepad-dev-client --local-proxy <agent-port> 19090 18080
curl -i http://127.0.0.1:19090/README.md
```

The remaining product path is moving this local listener into the iPad app and validating WebView origin behavior, WebSocket, HMR, SSE, and streaming responses.

## Docs

- [Architecture](docs/architecture.md)
- [MVP](docs/mvp.md)
- [Progress](docs/progress.md)
- [Technical Selection](docs/technical-selection.md)
- [Protocol](docs/protocol.md)
- [Security](docs/security.md)
