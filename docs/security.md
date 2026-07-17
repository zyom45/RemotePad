# RemotePad Security Model

Last updated: 2026-07-17

## Scope

This document covers the local MVP: one user, one continuously running Mac Agent, and one or more explicitly approved iPads on a trusted or untrusted local network. Relay, screen control, audio, and team access are outside this version.

## Protected Assets

- Terminal input, output, and active PTY sessions.
- Browser traffic to development servers on Mac loopback.
- iPad and Mac long-term signing private keys.
- Trusted-device decisions and device revocation state.
- Session metadata and security audit events.

## Trust Boundaries

- The local network and future relay are untrusted transports.
- Bonjour records are discovery hints and never establish trust.
- The iPad app trusts a Mac signing public key pinned during explicit pairing.
- The Mac Agent trusts only approved iPad signing public keys.
- A process already running as the same logged-in Mac user is inside the current trust boundary.
- An approved iPad receives Terminal and BrowserProxy permissions equivalent to remote control of the logged-in development account.

## Threats And Controls

### Network observation and modification

After authentication, every application frame is encrypted with ChaCha20-Poly1305. Each connection uses ephemeral X25519 key agreement and HKDF-SHA256 directional keys. Counters are authenticated and strictly increasing, rejecting replay and reordering.

### Handshake key substitution

The client and server ephemeral keys, nonces, device IDs, and protocol version are included in signed transcripts. The Mac signs its server hello with its pinned long-term identity key; the iPad signs the authentication transcript with its approved device key.

### Unauthorized device access

Pairing requires an iPad signature followed by explicit approval on the Mac. Unknown or revoked keys fail authentication. LAN and Bonjour exposure are disabled by default and require `--lan` or `REMOTEPAD_ENABLE_LAN=1`.

### Secret extraction

Long-term iPad and Mac signing identities are stored in Keychain with this-device-only accessibility. Previous UserDefaults identities are migrated and removed. Test-only file identities require explicit environment variables and are written with mode `0600`.

### Mac network pivoting

BrowserProxy targets are restricted by the Agent to `127.0.0.1`, `localhost`, or `::1`. The iPad cannot use BrowserProxy to reach arbitrary LAN or internet hosts through the Mac.

### Resource abuse

Frames have fixed maximum header and payload sizes. Terminal and BrowserProxy actions require successful authentication and an enabled permission. Connection rate limits, pairing throttles, and session-count limits are not implemented yet.

### Accountability

The Agent writes JSON Lines audit events to `~/Library/Application Support/RemotePad/audit.jsonl` with mode `0600`. Events include connections, pairing decisions, authentication outcomes, terminal lifecycle, BrowserProxy opens, trust, and revocation. Terminal contents and browser payloads are deliberately excluded.

## Residual Risks

- Initial pairing has no numeric comparison code; the user must approve the expected device name and fingerprint on the Mac.
- A compromised approved iPad can execute arbitrary commands as the logged-in Mac user.
- A malicious process already running as the Mac user can access the same development data and may alter non-Keychain application state.
- Audit logs are local, unsigned, and have no rotation or remote export yet.
- Pairing and trusted public-key records are not secrets, but their integrity is not yet backed by Keychain.
- There is no connection rate limiting or denial-of-service protection.
- PTY sessions are shared across approved clients under the current single-user model.
- SwiftPM development binaries can trigger macOS Keychain ACL prompts; signed application bundles are required for production distribution.

## Release Gates

Before external beta distribution:

1. Add a short authentication string or QR-based pairing confirmation.
2. Add connection and pairing rate limits plus session-count limits.
3. Move trusted-device decisions to Keychain-protected storage.
4. Add audit rotation and an in-app audit viewer.
5. Sign and notarize the Mac app and validate Keychain access across upgrades.
6. Complete real-iPad WebView tests for HMR, SSE, WebSocket, cookies, origin, and secure-context behavior.

Before Relay access:

1. Reuse the same E2E session above the relay transport.
2. Authenticate relay accounts without giving the relay device private keys.
3. Define metadata retention, abuse controls, and key-recovery behavior.
4. Perform an independent protocol and implementation review.
