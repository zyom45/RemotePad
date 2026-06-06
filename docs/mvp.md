# RemotePad MVP 仕様

RemotePad の最初の価値は、iPad から Mac の開発環境を必要十分に操作できることです。初期段階ではフル画面共有よりも、Terminal とローカル起動中の開発サーバーにアクセスできることを優先します。

## MVP の中心仮説

Mac 開発でリモートから本当に必要になる要素は、まず次の 3 つです。

- Codex や Claude を動かせる。
- Terminal 操作ができる。
- Mac でローカル起動している Web アプリやサービスをブラウザで確認できる。

この 3 つが満たせれば、iPad からのリモート開発体験の大部分は成立します。画面操作は初期 MVP の必須要件ではなく、次の段階で開発ワークフローを広げるための重要機能として扱います。

## MVP スコープ

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

1. Mac Agent と iPad App のペアリング。
2. E2E セキュアチャネル。
3. Terminal セッション。
4. Terminal セッションの永続化。
5. Mac localhost への iPad ブラウザ接続。
6. 開発サーバー一覧。
7. Codex / Claude CLI ワークフロー。
8. Git / diff / test の補助 UI。
9. 画面共有。
10. Mac GUI 操作。

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
