# RemotePad Progress

Last updated: 2026-06-29

This document tracks implementation progress against the product goal:
an iPad-first remote development client for a continuously running Mac.

## Current Position

RemotePad is in the local MVP foundation phase.

The most important vertical path is now proven:

1. A Mac agent starts a loopback-only RemotePad endpoint.
2. A client submits a signed pairing request.
3. The Mac stores the request and can approve it.
4. The approved device can authenticate.
5. The authenticated device can create and use a Mac PTY terminal.

This proves the core protocol, pairing, authentication, and terminal execution path. The product is not yet usable as a daily iPad app.

## Implemented

### Repository And Shared Protocol

- Swift Package based workspace.
- `RemotePadProtocol` shared library.
- RPAD frame encoder and decoder.
- Streaming frame decoder.
- JSON header helpers.
- Control, terminal, and browser proxy message models.
- Protocol tests for framing, control, terminal, and browser proxy messages.

### Mac Agent

- Loopback-only TCP listener.
- Optional Bonjour service model in the codebase, disabled by default.
- Agent device identity.
- Signed nonce authentication for trusted devices.
- Trusted device store.
- Pending pairing request store.
- CLI tools for listing, approving, rejecting, trusting, revoking, and clearing devices.
- Environment flag to disable automatic pairing approver launch:

```sh
REMOTEPAD_OPEN_PAIRING_APPROVER=0 swift run remotepad-agent
```

- Environment flag to bind the agent to a fixed local port for tests:

```sh
REMOTEPAD_AGENT_PORT=53244 swift run remotepad-agent
```

### Pairing

- Device identity with Curve25519 signing public key.
- Pairing start, challenge, response, result, and status messages.
- Signed pairing challenge verification.
- Pending pairing request persistence.
- Trusted device persistence.
- Pairing status check.
- Mac SwiftUI pairing approver app.
- Agent can open the Mac pairing approver automatically when a request arrives.

### Terminal

- Agent-managed PTY terminal creation.
- Terminal input and output.
- Terminal list.
- Terminal attach.
- Terminal close.
- Recent output replay on attach.
- Development client can authenticate and create a terminal.

### Browser / Localhost Access

- HTTP BrowserProxy spike for Mac localhost fetches.
- TCP BrowserProxy stream for Mac localhost tunnels.
- Development local listener that forwards `127.0.0.1:<listen>` to Mac localhost over BrowserProxy stream.
- iPad WebView scaffold and local listener wiring.

### iPad App Scaffold

- SwiftUI app scaffold.
- Host and port input.
- Pairing request action.
- Pairing status action.
- Initial terminal workspace.
- Authenticated terminal connect / disconnect.
- Terminal command input.
- Terminal escape and tab helper keys.
- Terminal interrupt.
- Terminal output clear.
- SwiftTerm-backed terminal rendering.
- Terminal resize propagation.
- Terminal input via SwiftTerm keyboard handling.
- WebView scaffold.
- Local browser proxy scaffold.

### Development CLI

- Identity creation and reset.
- Pairing request.
- Pairing status.
- Authenticated terminal check.
- Browser GET check.
- Browser stream check.
- Local proxy check.
- One-command local integration check:

```sh
scripts/check-local-integration.sh
```

## Verified

Latest verified flow:

```sh
scripts/check-local-integration.sh
```

The script covers:

```sh
REMOTEPAD_OPEN_PAIRING_APPROVER=0 REMOTEPAD_AGENT_PORT=<port> swift run remotepad-agent
swift run remotepad-dev-client --pair <agent-port> "RemotePad Dev iPad"
swift run remotepad-agent --approve-pairing <device-id>
swift run remotepad-dev-client --pair-status <agent-port>
swift run remotepad-dev-client <agent-port> --close-after-ready
swift run remotepad-agent --revoke-device <device-id>
swift test
```

Observed results:

- Pairing request returned `pending_approval`.
- Approval moved the device into the trusted store.
- Pairing status returned `approved`.
- Authenticated terminal session was created.
- Terminal printed `__REMOTEPAD_READY__`.
- Terminal closed cleanly.
- Verification device was revoked after the test.
- `swift test` passed with 34 tests.

## Not Yet Implemented

### iPad Daily-Use Terminal

- Terminal emulator UI with ANSI rendering.
- Keyboard input polish.
- External keyboard shortcuts.
- Resize handling from the iPad UI.
- Session picker and reconnection UI.

### iPad Daily-Use Browser

- Dev server list beyond fixed presets.
- Rich URL entry for Mac localhost targets.
- WebSocket, HMR, SSE, chunked response, and cookie/origin validation on real iPad hardware.

### Production Security

- Keychain storage for device identities and trusted keys.
- Application-layer E2E encryption after pairing.
- Threat model document.
- Audit log.
- User-visible permission policy.
- LAN exposure gate after UI pairing and revocation are complete.

### Mac App Experience

- Menu bar agent.
- Launch at login.
- Agent status window.
- Pairing notifications.
- Signed/notarized app bundle.

### Remote Access

- Out-of-home connection path.
- Relay protocol.
- NAT traversal.
- P2P fallback strategy.
- Relay server deployment model.

### Later Product Features

- Screen sharing.
- Keyboard and pointer injection.
- Audio output.
- Audio input or voice dictation.
- Clipboard sync.
- File bridge.
- Codex / Claude session-specific UI.
- Git, diff, test, and command palette UI.

## Goal Progress

Approximate status:

- Secure local pairing and authentication foundation: 40%
- Terminal backend: 50%
- iPad terminal product experience: 35%
- Mac localhost browser backend: 35%
- iPad browser product experience: 30%
- Mac agent product experience: 25%
- Out-of-home secure connection: 5%
- Screen sharing: 0%
- Audio: 0%
- Codex / Claude specialized workflow: 10%

Overall product progress: roughly 25-30%.

## Next Recommended Work

1. Validate iPad Browser WebView behavior for WebSocket, HMR, SSE, cookies, and origin handling.
2. Improve iPad terminal session picker and reconnect behavior.
3. Move Mac agent into a menu bar app with pairing status and approvals.
4. Define the production security model before enabling LAN exposure.
5. Add Keychain storage for identities and trusted keys.

## Documentation Map

- [Architecture](architecture.md): product architecture and long-term system shape.
- [MVP](mvp.md): MVP scope and prioritization.
- [Technical Selection](technical-selection.md): implementation choices.
- [Protocol](protocol.md): wire protocol details.
- This file: implementation status and verification history.
