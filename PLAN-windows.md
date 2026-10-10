# notify-flash Windows 版実装計画

## 目的

macOS 版と同じ体験を Windows で実現する。通知バナーが出たら、フォーカス中ウィンドウのあるディスプレイの縁をアプリ別・文字列ルール別の色で点滅させる。見逃し防止が目的で、OS 標準の全画面点滅は使わない。

## Mac 版の解析（移植の単位）

| 層 | Mac 実装 | 性質 | Windows への扱い |
|---|---|---|---|
| 捕捉 | `Capture.swift`。AX で `com.apple.notificationcenterui` を購読し、`AXNotificationCenterBanner` から uuid・title・body・AXDescription を取る | OS 固有 | 作り直す（下記 Spike A） |
| アプリ名抽出 | `extractAppName`。AXDescription 内で title を検索し、手前を名前とする | Mac の文字列書式に依存 | 不要。Windows は送信元を構造化データで得られる見込み |
| 重複排除 | `Seen`。uuid の FIFO 64 件 | 純ロジック | そのまま移植（キーは通知 ID） |
| 設定 | `Config.swift`。JSON、`count` 1〜10 で不正は 3、色は `#RRGGBB` のみ、rules は部分一致で apps より優先、表示名は大文字小文字区別 | 純ロジック | 仕様を完全踏襲。ファイルは同一形式 |
| 描画 | `Glow.swift`。全画面の透明・クリック透過・最前面ウィンドウに縁枠。150ms 点灯 + 250ms 消灯を count 回、世代番号で古いタイマーを無効化、reduce motion で 1 回 | OS 固有 | 作り直す（下記 Spike B） |
| 画面選択 | AX のフォーカス窓の中心点から `pickScreen` | 純関数 + OS 固有の取得 | `pickScreen` は移植。取得は `GetForegroundWindow` + `MonitorFromWindow` |
| 常駐 UI | NSStatusItem。ON/OFF、設定を開く、終了 | OS 固有 | 通知領域アイコン |
| 自己テスト | `--self-test <ID>`。E/D/S/A/C/R/I | 純ロジック | 同じ ID と期待値を移植（E は不要になれば削除） |

仕様は `PLAN.md` と `Config.swift` の挙動が正。Windows 版で変えるのは捕捉・描画・常駐 UI の 3 点だけ。

（2026-10-10 変更）描画は macOS 版 0e01eb0 に合わせて 4 スタイル（`soft` 既定 / `breath` / `orbit` / `corner`）。設定 `"style"`、`--flash-test '#RRGGBB' [style]`。`UpdateLayeredWindow` で画素ごとの不透明度を毎フレーム描く。`corner` は Windows のトースト位置に合わせて右下から広がる（macOS は右上）。

（2026-10-10 追加）設定 `"display"` で光らせるディスプレイを固定できる。値はデバイス名（`"DISPLAY4"`、完全一致）かモニタ名の部分一致（`"HP U32"`、大文字小文字無視）。DISPLAYn はモニタ再接続で番号が変わり、Windows 設定の表示番号とも一致しないため、モニタ名を推奨する。一覧は `NotifyFlash.exe --list-displays`。未指定・該当なしはフォーカス中の画面。設定 `"size"`（既定 1、0.25〜5、範囲外・数値以外は 1）は全スタイルの長さ（にじみ半径・奥行き・帯幅）に掛ける倍率。AppUserModelId が未登録の送信元（ポータブル版 WezTerm など）は `UserNotification.AppInfo` が E_NOTIMPL になる。その場合は送信元名を空にしてタイトル・本文の `rules` だけで判定する（Claude Code フックの PowerShell トースト `'Claude Code'` もこれに当たる）。`apps` で照合したい送信元は`HKCU\Software\Classes\AppUserModelId\org.wezfurlong.wezterm` に `DisplayName=WezTerm` を登録すると送信元名 `WezTerm` で届く（2026-10-10 実機確認）。

## 最大の未確定事項と検証順

捕捉方式が成否を決める。Mac 版と同じく、本体より先に PoC で検証する。Windows 実機が要るため、WSL 上では検証できない。

**Spike A: 捕捉方式（未検証）**

| 案 | 内容 | 懸念 |
|---|---|---|
| A1 `UserNotificationListener`（WinRT） | 公式 API。送信元アプリ名・title・body を構造化して得られる見込み。Mac の文字列切り出しが不要になる | 利用者の許可が要る。拒否後は設定画面での手動許可が必要。非パッケージ Win32 では `RequestAccessAsync` が Allowed でも購読が `0x80070490` で失敗する報告がある。パッケージ ID（MSIX の薄い包み、または sparse package）が必要な可能性が高い |
| A2 UI Automation | Mac 版の AX と同じ発想。トーストの UIA ツリーを購読する | 通知を描画するシェルのプロセスと要素名が未確認。Win10 / Win11 で構造が違う可能性。UIA 側のイベント購読が通知バナーを確実に拾うかも不明 |

判定手順:
1. Windows 実機で `Accessibility Insights` または `inspect.exe` を使い、トースト表示中の UIA ツリーを採取する（A2 の可否）。
2. 最小の .NET コンソールで A1 を非パッケージのまま試す。失敗したらパッケージ ID 付きで再試行する。
3. 採用基準は「terminal-notifier 相当（Claude Code の通知を出すもの）で送信元と title / body が取れる」「1 バナー 1 回だけ発火する」「集中モード（フォーカス アシスト）で抑止された通知は拾わない」の 3 点。A1 が通れば A1、通らなければ A2。
4. 採取結果は `poc-windows/FINDINGS.md` に「検証済み / 未検証」を分けて記録する（Mac の `poc/FINDINGS.md` と同じ作法）。

**Spike B: 描画（未検証）**

全画面の透明・クリック透過・最前面ウィンドウを作る。候補は WPF か WinForms のレイヤード ウィンドウ（`WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`）。確認事項は次のとおり。
- クリックが下のウィンドウへ通る。
- 排他的フルスクリーンのゲーム等では出ない可能性が高い。ボーダーレス フルスクリーンでは出るかを確かめ、出ない場合は既知の限界として記載する。
- 高 DPI とマルチモニタで、座標とスケールが合う（Per-Monitor DPI V2 を宣言する）。
- reduce motion は `SystemParameters.ClientAreaAnimation` で判定する（未検証）。

## 技術選定（案）

- 言語: C# / .NET（`net8.0-windows10.0.19041.0`）。理由は WinRT・UIA・WPF・通知領域アイコンがそろい、`System.Text.Json` が Mac 版の JSON をそのまま読めること。外部 NuGet は追加しない方針（A1 でパッケージ ID が要る場合のみマニフェストを足す）。
- ディレクトリは `windows/`。Mac 版 `macos/` と対称にする。
- ファイル構成は Mac 版に対応させる。`Program.cs`（入口・自己テスト振り分け・通知領域）、`Capture.cs`、`Glow.cs`、`Config.cs`。1 実装だけの interface は置かない。
- 設定ファイルの解決順は focusbm（`BookmarkPaths.cs`）に倣う。
  1. exe と同じディレクトリの `config.json`（存在する場合）。`AppContext.BaseDirectory` と `Environment.ProcessPath` の両方を見る。
  2. なければ `%USERPROFILE%\.config\notify-flash\config.json`（Mac と同じ相対パス）。
  - 解決はバナーごとの読み込み時に毎回行う（Mac 版の「バナーごとに読む」を踏襲）。
  - 既定ファイルの生成は、1 も 2 も無いときだけ 2 に作る。exe 隣には作らない。既存ファイルは上書きしない。
  - 「設定ファイルを開く」は解決後のパスを開く。
  - focusbm にある環境変数による上書きは、依頼が無いので入れない。
- 自己テストは `NotifyFlash.exe --self-test <ID>...`。終了コードも Mac と同じ（未登録 ID と失敗は 1、成功は 0、ID 無指定は 2）。`Debug.Assert` は使わない（Release で消えるため）。

## 工程

直列。01 の結果で 02 以降の捕捉部分が変わる。

| 番号 | 題 | files | 依存 | 検証面 |
|---|---|---|---|---|
| 01 | Spike A: 捕捉の PoC と FINDINGS | `poc-windows/` | なし | 実機。人手 |
| 02 | Spike B: 描画の PoC | `poc-windows/` | なし（01 と並行可） | 実機。人手 |
| 03 | 土台と設定 | `windows/*.csproj`、`Config.cs`、`Program.cs` | なし（PoC と並行可） | CLI。`--self-test A1〜A6 C1 C2 R1 P1〜P3` |
| 04 | 捕捉 | `Capture.cs` | 01、03 | CLI。`D1〜D5`、実機で 1 バナー 1 発火 |
| 05 | 描画・画面選択 | `Glow.cs` | 02、03 | CLI。`C3 C4 S1 S2`、`--flash-test '#RRGGBB'` |
| 06 | 統合・通知領域・ルート Makefile | `Program.cs`、`Makefile` | 04、05 | CLI。`I1〜I3`、実機 |

工程 03 は Mac の `Config.swift` を機械的に移植できるので、PoC を待たずに着手できる。独立した並行作業はここだけ。

## 受入

機械検証（Windows 上）:

```
NotifyFlash.exe --self-test D1 D2 D3 D4 D5 C3 C4 S1 S2 A1 A2 A3 A4 A5 A6 C1 C2 R1 P1 P2 P3 I1 I2 I3
```

E1〜E6 は Mac の AXDescription 解析用なので、Windows 版が構造化データを使うなら対象外。文字列解析を残す場合のみ移植する。

設定解決の自己テストを追加する（一時ディレクトリを使い、実際の `%USERPROFILE%` は触らない）。
- P1: exe 隣に `config.json` がある → それを返す（フォールバック先にもあっても exe 隣を優先）。
- P2: exe 隣に無く、フォールバック先にある → フォールバック先を返す。
- P3: どちらも無い → フォールバック先を返し、既定生成は exe 隣に作らない。

人手確認（Mac の (a)〜(f) に対応）:
- (a) 通知の許可を付与し、起動して捕捉状態になる。
- (b) `apps` に登録した送信元で実際の通知を 1 件出し、フォーカス中ディスプレイの縁が設定色で count 回光る。クリックが下の窓に通る。
- (c) 複数ディスプレイで、フォーカスのないディスプレイは光らない。
- (d) 通知領域アイコンから ON/OFF と設定ファイルを開ける。OFF は点灯中でも即消える。
- (e) Slack 等の実アプリ通知で送信元名が取れる。
- (f) 全画面アプリ（ボーダーレス）上で縁が光る。

## 既知の限界（対処せず記載する想定）

- 排他的フルスクリーンでは縁が出ない可能性がある。
- 集中モード（フォーカス アシスト）で抑止された通知は拾えない見込み（未検証）。
- 通知センターのパネルを開いたときの誤発光は未検証。
- 配布・署名・ログイン時自動起動・GUI 設定編集は対象外（Mac 版と同じ）。

## 利用者判断

確定済み（2026-10-10 利用者回答）:

1. 設定ファイルは exe と同じディレクトリを優先し、なければ `%USERPROFILE%\.config\notify-flash\config.json`（focusbm と同じ方式）。
2. Windows ネイティブ常駐。
3. A1 がパッケージ ID を要求したら MSIX パッケージ化まで許容する。
4. 実機 PoC は利用者が実行してログを持ち帰る。Claude からは Windows を操作できない。
