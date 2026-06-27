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
- Development CLI client
- Unit tests for frame, control, terminal, and browser proxy messages

Current authentication uses a signed nonce challenge. The development client sends a Curve25519 signing public key in `ClientHello`, signs the auth transcript, and the agent verifies `AuthProof.signature`. Until real pairing UI and audit logs are implemented, trusted devices are managed with explicit development CLI commands and the agent remains loopback-only without Bonjour.

To trust the development client:

```sh
swift run remotepad-dev-client --identity
swift run remotepad-agent --trust-device <device-id> <public-key-base64>
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
- [Technical Selection](docs/technical-selection.md)
- [Protocol](docs/protocol.md)
