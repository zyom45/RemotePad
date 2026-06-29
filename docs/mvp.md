# RemotePad MVP 仕様

RemotePad の最初の価値は、iPad から Mac の開発環境を必要十分に操作できることです。初期段階ではフル画面共有よりも、Terminal とローカル起動中の開発サーバーにアクセスできることを優先します。

## MVP の中心仮説

Mac 開発でリモートから本当に必要になる要素は、まず次の 3 つです。

- Codex や Claude を動かせる。
- Terminal 操作ができる。
- Mac でローカル起動している Web アプリやサービスをブラウザで確認できる。

この 3 つが満たせれば、iPad からのリモート開発体験の大部分は成立します。画面操作は初期 MVP の必須要件ではなく、次の段階で開発ワークフローを広げるための重要機能として扱います。

## MVP スコープ

### 現在の実装ゲート

現時点の Mac Agent はプロトコルと開発体験の検証段階です。署名チャレンジ検証、ペアリング要求、Mac 側承認、デバイス失効の基礎は実装済みですが、Keychain 保存、E2E 暗号、監査ログ、LAN 公開時の安全ゲートが未完成のため、次を必須条件にします。

- Mac Agent は loopback-only で待ち受ける。
- Bonjour / mDNS で LAN に公開しない。
- `0.0.0.0`、LAN IP、外出先接続、Relay 接続では利用しない。
- Terminal と BrowserProxy はローカル検証用として扱う。

このゲートは [#2](https://github.com/zyom45/RemotePad/issues/2) の完了条件です。

### 1. Terminal

iPad から Mac Agent 経由で Terminal セッションを操作します。

機能:

- Mac Agent が PTY を起動する。
- iPad App は SwiftTerm で Terminal を表示する。
- shell、Codex CLI、Claude CLI、git、npm、pnpm、bun、make などを実行できる。
- tmux または zellij セッションに復帰できる。
- 複数 Terminal タブを扱える。
- 外部キーボードと補助キーバーを使える。
- セッション切断後も Mac 側プロセスを維持できる。

重要ポイント:

- SSH アプリとしてではなく、RemotePad セッション内の Terminal として提供する。
- 通信は RemotePad の認証済み E2E チャネルを使う。
- 通常 SSH は互換モードとして後から追加できる。
- MVP では Agent 管理 PTY を採用する。

### 2. Local Browser Access

Mac で起動しているローカル開発サーバーを iPad から確認できるようにします。

機能:

- Mac Agent がローカルポートを検出または登録する。
- iPad App に開発サーバー一覧を表示する。
- `localhost:3000`、`localhost:5173`、`localhost:8080` などへアクセスできる。
- iPad App 内ブラウザまたは Safari で開ける。
- 必要に応じて Mac Agent 経由で HTTP/WebSocket をプロキシする。
- dev server の起動、停止、再起動コマンドを Terminal から実行できる。

重要ポイント:

- iPad の `localhost` ではなく、Mac 側の localhost に接続する。
- 外出先でも VPN 手動起動なしで使えることを目指す。
- WebSocket、HMR、SSE など開発サーバー特有の通信を壊さない。
- MVP では iPad App 内 WebView を優先し、必要に応じて Safari で開く導線を用意する。

方式判断:

- 現在の HTTP request / response BrowserProxy は検証用スパイクとする。
- 本命は iPad 側で `127.0.0.1:<local-port>` を開き、RemotePad セッションを通して Mac 側 `127.0.0.1:<target-port>` へ接続するローカルポートプロキシとする。
- HMR、WebSocket、SSE、chunked response、大きな静的アセットを壊さないため、BrowserProxy は生 TCP stream またはそれに近い双方向ストリームを優先する。
- WebView の secure context、cookie、origin、CORS の挙動は早期に実機検証する。

### 3. AI Agent Workflow

Codex と Claude を Terminal から動かし、入力待ちや作業継続を iPad で扱いやすくします。

機能:

- Codex / Claude CLI を起動できる。
- 実行中 Terminal セッションを一覧できる。
- 入力待ち状態を通知できる。
- iPad からプロンプトを送れる。
- 音声文字起こしプロンプトは後続フェーズで追加する。
- 差分確認、テスト実行、承認操作を Terminal と Git View から行える。

重要ポイント:

- 初期は CLI ベースで十分。
- Codex / Claude の GUI アプリ操作は画面操作フェーズで扱う。
- モバイル版 Codex / Claude アプリとの連携は、セッション継続やコンテキスト共有の観点で後から設計する。

## 次ステップ: 画面操作

Terminal とローカルブラウザ接続だけで多くの開発作業は成立しますが、次の用途には画面操作が必要です。

- Codex / Claude の Mac アプリを立ち上げる。
- GUI アプリ上で実装タスクを開始する。
- エディタやブラウザの状態を直接確認する。
- ネイティブアプリ、デスクトップアプリ、シミュレータを確認する。
- モバイル版 Codex / Claude アプリで続きができるよう、Mac 側アプリの状態を確認する。

画面操作は MVP 後の重要機能として、WebRTC ベースの低遅延画面共有と入力イベント送信で実装します。

## 優先順位

1. 仮認証中の安全ゲート: loopback-only、Bonjour 無効、LAN 公開禁止。
2. フレーム仕様の固定: endian、最大サイズ、request_id、圧縮交渉、version mismatch。
3. Mac Agent と iPad App のペアリング。
4. 署名チャレンジによるデバイス認証。
5. E2E セキュアチャネル。
6. Terminal セッション。
7. Terminal セッションの永続化。
8. Mac localhost への iPad ブラウザ接続。
9. iPad ローカルポートプロキシと WebView origin 検証。
10. 開発サーバー一覧。
11. Codex / Claude CLI ワークフロー。
12. Git / diff / test の補助 UI。
13. 画面共有。
14. Mac GUI 操作。

## Issue 反映済み計画

- [#1](https://github.com/zyom45/RemotePad/issues/1): Relay 前に Noise 系を含むアプリ層 E2E 暗号を決定する。
- [#2](https://github.com/zyom45/RemotePad/issues/2): UI ペアリングと失効フローが入るまでは loopback-only とし、Bonjour / LAN 公開を禁止する。
- [#3](https://github.com/zyom45/RemotePad/issues/3): フレーム仕様を実装と一致させる。
- [#4](https://github.com/zyom45/RemotePad/issues/4): HTTP-aware BrowserProxy はスパイク、本命はローカルポートプロキシ + 双方向ストリームとする。
- [#5](https://github.com/zyom45/RemotePad/issues/5): WebView の localhost origin 問題を早期検証する。
- [#6](https://github.com/zyom45/RemotePad/issues/6): 脅威モデルをセキュリティモデルに追加する。
- [#7](https://github.com/zyom45/RemotePad/issues/7): 再接続とセッション再開を Terminal 永続化の次に仕様化する。
- [#8](https://github.com/zyom45/RemotePad/issues/8): MVP は単一ユーザー / 単一操作主体として明記し、複数クライアントは後続設計に分離する。
- [#9](https://github.com/zyom45/RemotePad/issues/9): Discovery は信頼根ではなくヒントとして扱い、信頼は pinned public key に紐づける。
- [#10](https://github.com/zyom45/RemotePad/issues/10): 推奨 repo 構成と現在の実装ステータスを分けて記述する。
- [#11](https://github.com/zyom45/RemotePad/issues/11): `protocol_version_unsupported` の処理フローを定義する。

## MVP でやらないこと

- フル機能のリモートデスクトップ。
- 仮想マイク。
- Mac 音声出力転送。
- 専用 VPN 実装。
- チーム管理。
- 複雑な AI セッション同期。

これらは初期の開発体験が成立した後に追加します。

## 初期判断

最初に作るべきものは、SSH クライアントでも画面共有アプリでもありません。RemotePad の最初の形は、Mac Agent と iPad App が作る「安全な開発セッション」です。その中に Terminal と Mac localhost ブラウザ接続を入れることで、iPad から Mac の開発作業をほぼ進められる状態を目指します。

初期実装では Swift ネイティブの iPad App と Mac Agent を採用し、LAN 直結、デバイス鍵によるペアリング、Agent 管理 PTY、Agent 経由 localhost proxy を実装します。外出先接続は将来の E2E Relay を前提にプロトコルを設計します。
