# RemotePad 技術選定

このドキュメントは、実装開始前に合意した初期技術方針をまとめます。RemotePad は SSH アプリや画面共有アプリではなく、Mac 上の開発環境に iPad から安全・低遅延に接続するための単一アプリ体験を目指します。

## 決定事項

### 1. アプリはネイティブ Swift

RemotePad は iPad App と Mac Host Agent の両方を Swift ネイティブで実装します。

理由:

- iPad の外部キーボード、トラックパッド、Apple Pencil、Face ID、Keychain、Files、Stage Manager と相性がよい。
- Mac 側のメニューバー常駐、Keychain、Bonjour、ローカルプロセス管理、PTY 管理と相性がよい。
- 将来的な画面収録、アクセシビリティ、音声、Network Extension への拡張余地がある。
- WebView 中心のアプリよりも入力操作と低遅延 UI を作り込みやすい。

初期構成:

- iPad App: SwiftUI
- Mac Agent: SwiftUI または AppKit ベースのメニューバー常駐アプリ
- 共有コード: Swift Package

### 2. MVP は SSH ではなく Agent 管理 PTY

Terminal は通常 SSH ではなく、Mac Agent が PTY を起動し、RemotePad のセキュアチャネル上で iPad に提供します。

理由:

- RemotePad の単一アプリ体験を保てる。
- 接続、認証、権限、監査ログを RemotePad 側で統一できる。
- Codex / Claude の実行状態、入力待ち、通知、セッション復帰を扱いやすい。
- 将来の開発コックピット、Git View、コマンドパレットと統合しやすい。

通常 SSH は後から互換モードとして追加できます。

### 3. MVP 接続は LAN 直結

最初は LAN 内で Mac Agent を発見し、iPad App から直接接続します。

方式:

- Bonjour / mDNS で Mac Agent を検出。
- 署名済みX25519鍵交換とChaCha20-Poly1305によるE2Eセッションを確立。
- iPad と Mac の鍵は Keychain に保存。
- 初回ペアリングは Mac 側承認を必須にする。

外出先接続は MVP 後に実装しますが、プロトコルはリレー経由でも使える形にします。

実装ゲート:

- 署名チャレンジ検証は実装済み。
- ペアリング要求、Mac 側承認、デバイス失効の基礎は実装済み。
- デバイス秘密鍵はKeychainへ保存し、既存UserDefaults鍵は初回起動時に移行する。
- 認証後の全フレームは一時X25519鍵、HKDF-SHA256、ChaCha20-Poly1305でE2E暗号化する。
- Macの長期署名鍵で一時鍵を含むhandshake transcriptへ署名し、iPadはペアリング時にpinしたMac公開鍵で検証する。
- LAN / Bonjour公開は既定で無効とし、`--lan` または `REMOTEPAD_ENABLE_LAN=1` の明示指定時だけ有効にする。
- LANモードは固定ポート `53241` を既定とし、`REMOTEPAD_AGENT_PORT` で上書きできる。

### 4. 外出先接続は VPN 内蔵より E2E Relay 優先

RemotePad の目的は「プライベートネットワーク全体へ入ること」ではなく、「自分の Mac Agent に安全に届くこと」です。そのため、初期の将来方針としては内蔵 VPN より E2E Relay を優先します。

方針:

- Mac Agent が Relay に外向き常時接続する。
- iPad App も Relay に接続する。
- Relay は経路確立と中継だけを担当する。
- セッション内容は iPad と Mac Agent 間で E2E 暗号化する。
- P2P 接続が可能なら直接化し、不可なら Relay 中継にフォールバックする。

Tailscale / WireGuard / Cloudflare Zero Trust は設計上の参考または互換・検証手段として扱い、最終 UX では別アプリの手動起動を前提にしません。

### 5. localhost ブラウザ接続は Agent Proxy

Mac で起動している `localhost:3000` などの開発サーバーへ、iPad App から接続できるようにします。

初期スパイク:

- Mac Agent が Mac 側 localhost へ HTTP/WebSocket プロキシする。
- iPad App は RemotePad セキュアチャネル経由でプロキシに接続する。
- iPad App 内 WebView で表示する。
- 必要に応じて Safari で開く導線も提供する。

本命方式:

- iPad App が `127.0.0.1:<local-port>` でローカルリスナーを立てる。
- WebView はその iPad 側 localhost を開く。
- iPad App は RemotePad セッション上の BrowserProxy stream に変換する。
- Mac Agent は Mac 側 `127.0.0.1:<target-port>` に接続する。
- HTTP、WebSocket、SSE、HMR、chunked response を同じ双方向ストリームで扱う。

重要要件:

- WebSocket、HMR、SSE に対応する。
- iPad の `localhost` と Mac の `localhost` を混同しない。
- ポート一覧を自動検出または手動登録できる。
- WebView の secure context、cookie、CORS、origin の挙動を実機で検証する。

### 6. セッションは Agent 管理 + tmux 互換

RemotePad は Mac Agent 側で Terminal セッション一覧と状態を管理します。ただし、tmux や zellij を使うユーザーの運用も妨げません。

方針:

- RemotePad Terminal は Agent 管理 PTY として起動する。
- 切断してもセッションを維持する。
- iPad App からセッション一覧に復帰できる。
- ユーザーが tmux / zellij を使う場合も自然に利用できる。
- 将来的には Codex / Claude セッションを検出してラベル付けする。

## 初期プロトコル方針

RemotePad セッションは複数の論理チャネルを持つ構造にします。

詳細は [protocol.md](protocol.md) にまとめます。

チャネル:

- Control: ペアリング、認証、能力交換、設定、状態通知。
- Terminal: PTY 入出力、リサイズ、セッション管理。
- BrowserProxy: HTTP、WebSocket、SSE のプロキシ。
- Clipboard: クリップボード同期。
- DevTools: Codex、Claude、Git、開発サーバー状態。
- Screen: 将来の画面共有。
- Audio: 将来の音声入出力。

MVP では Control、Terminal、BrowserProxy を優先します。

## Mac Agent 初期権限

MVP では権限要求を最小限にします。

必要:

- Keychain
- ローカルネットワーク
- PTY / shell 起動
- メニューバー常駐

後続フェーズ:

- 画面収録
- アクセシビリティ
- 入力監視
- マイク
- オートメーション
- フルディスクアクセス

初期から多くの権限を求めず、機能追加時に必要な権限だけ段階的に要求します。

## iPad App 初期 UI

MVP で必要な画面:

- Paired Macs
- Connect / Unlock
- Terminal
- Dev Servers
- In-App Browser
- Session Status
- Settings

Terminal には開発者向け補助キーバーを用意します。

補助キー:

- Esc
- Tab
- Ctrl
- Option
- Cmd
- 矢印
- Function キー
- よく使うコマンドスニペット

## 推奨リポジトリ構成

```text
RemotePad/
  apps/
    ipad/
    mac-agent/
  packages/
    RemotePadCore/
    RemotePadProtocol/
  docs/
    architecture.md
    mvp.md
    technical-selection.md
```

## 現在の実装ステータス

現在の実体:

```text
RemotePad/
  apps/
    ipad/
    mac-agent/
    mac-pairing-approver/
  packages/
    RemotePadAgentSupport/
    RemotePadProtocol/
  tools/
    dev-client/
  docs/
```

未実装:

- `packages/RemotePadCore/`
- Mac メニューバー常駐
- LAN Discovery
- 実iPadでのWebView互換性検証
- E2E Relay

推奨構成は維持しますが、実装は Mac Agent、共有Protocol、開発用CLIから開始しています。

## 実装開始時の最小成果物

最初の実装スプリントでは、次の状態を目指します。

- Mac Agent が起動する。
- iPad App が Mac Agent を LAN 検出する。
- 初回ペアリングできる。
- iPad App から Agent 管理 PTY に接続できる。
- Terminal で shell を操作できる。
- Terminal セッションを切断後に復帰できる。
- Mac のローカル開発サーバーを iPad App 内ブラウザで開ける。

## 保留事項

- Relay transportをWebSocket、QUIC、WebRTC DataChannelのどれにするか。
- WebView と Safari 連携の具体仕様。
- Relay サーバーの実装言語と運用方式。
