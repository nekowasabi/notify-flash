# notify-flash macOS 版実装計画

## 目的

大画面では右上の通知バナーが周辺視野外にあり、通知を見逃す。フォーカス中ウィンドウのあるディスプレイの縁をアプリ別の色で光らせ、見逃しを減らす。OS 標準の全画面点滅は不快なため使わない。PoC の捕捉結果をもとに本体を作る。

## 対象外

Windows 版の実装、集中モード、配布・署名、ログイン時自動起動、GUI 設定編集、通知センターパネルの誤発光除外、NotificationCenter 再起動後の自動再接続。
Windows 版は後続計画とし、設定形式 JSON を System.Text.Json でも読める形に揃えることだけを考慮する。

## 制約

- PoC 記録の環境は macOS 26.6.2 / Apple Swift 6.3.3。根拠は `poc/FINDINGS.md` と `poc/main.swift`。外部依存・SPM・Xcode プロジェクトを追加しない。
- `poc/` は使い捨てで変更しない。本体は `macos/` に新設する。Swift は `main.swift`、`Capture.swift`、`Glow.swift`、`Config.swift` の 4 本。1 実装だけの抽象化や `protocol` は置かない。
- （2026-10-10 変更）`make` で `macos/NotifyFlash.app`（LSUIElement、アドホック署名、bundle id `com.notifyflash.app`）を作り `open` で常駐起動する。AX 権限はアプリに付与し、未付与なら付与を待って捕捉を開始する。再ビルドのたびに許可はリセットされ、再付与が要る。
- `macos/Makefile` は `swiftc -O *.swift -o notify-flash`。ルート `Makefile` は `make -C macos` に委譲する。windows ターゲットは後続計画。
- 自己テスト入口は `notify-flash --self-test <ID>...`。未登録 ID または失敗は終了コード 1、全通過は 0、ID 無指定は 2。`precondition` または明示 `exit(1)` を用い、最適化で消える `assert(` は禁止する。
- 自己テストの分岐は AX 権限確認と NSApplication 生成より前。各 Swift ファイルに自身の自己テスト関数を置き、main.swift で振り分ける。自己テストは AX を呼ばず、実際の `~/.config` を触らず一時ディレクトリを使う。
- 捕捉は `com.apple.notificationcenterui` に AXWindowCreated / AXCreated / AXLayoutChanged / AXUIElementDestroyed を購読し、`AXSubrole=AXNotificationCenterBanner` を探す。AXDescription は属性一覧に出なくても名前指定で問い合わせる。子 AXStaticText の AXIdentifier が title / body の AXValue を取得する。全属性ダンプは持ち込まない。
- アプリ名は title の AXValue を AXDescription 内で先頭から検索し、その手前の末尾の句読点・空白を除く。title が空なら body を使う。両方空・検索失敗・結果が空なら nil として発光しない。読点分割へ戻さない。設定はバンドル ID ではなく表示名。
- 重複排除は UUID の AXIdentifier 単位。抽出成功後に初めて既見に記録し、直近 64 件を FIFO で保持する。UUID 空は発光しない。Destroyed で既見を削除しない。
- 設定は `~/.config/notify-flash/config.json`、形は `{"count":3,"apps":{"terminal-notifier":"#FF8800"}}`。Foundation の JSONDecoder / Codable でバナーごとに読む。ファイル監視・再読込メニューは置かない。
- 起動時にファイルが無ければ `{"count":3,"apps":{}}` を生成する。既存ファイルは上書きしない。壊れた JSON は stderr に 1 行出して発光しない。count は 1〜10 以外なら 3。色が `#RRGGBB` 以外のアプリ項目は無視する。表示名は大文字小文字を区別する完全一致。
- NSStatusItem のメニューは ON/OFF 切替、設定ファイルを開く、終了。開く操作はファイルが無ければ既定を作り NSWorkspace.open を使う。ON/OFF はメモリのみで起動時 ON。OFF にしたら点灯中のオーバーレイも即非表示。
- 描画は全画面サイズの NSWindow。borderless、isOpaque=false、backgroundColor=.clear、ignoresMouseEvents=true、level=.screenSaver、collectionBehavior は canJoinAllSpaces と fullScreenAuxiliary。アプリ色の縁枠だけを描く。
- 発光初期値は推定で、幅 6pt、不透明度 0.8、点灯 150ms＋消灯 250ms を count 回。定数とし、推定であることをソースコメントにも書く。accessibilityDisplayShouldReduceMotion が真なら点灯 1 回。回数は全体共通でアプリ別に持たない。
- 発光中の新要求は世代番号で古いタイマーを無効化し、新しい色で最初から開始する。Timer / asyncAfter を使い、待機でランループを止めない。
- 画面は AXUIElementCreateSystemWide → AXFocusedApplication → AXFocusedWindow → AXPosition / AXSize の中心点から選ぶ。主画面左上原点・下向きの AX 座標を `y = 主画面高さ − y` で NSScreen 座標へ変換する。
- 純粋関数 `pickScreen(point: CGPoint?, frames: [CGRect]) -> Int` は含む画面の添字を返し、点が取れない・含む画面がないときは 0。主画面は NSScreen.screens[0]。
- `notify-flash --flash-test '#RRGGBB'` は同じ画面選択で 1 回分の点滅後に終了する人手確認用入口。AX 権限が無ければ主画面。
- 既知の限界は対処せず記載する。通知センターパネル表示時の誤発光は未検証で誤爆許容。NotificationCenter 再起動後は捕捉停止を本体の再起動で復帰させる。terminal-notifier 経由はすべて同じアプリ名。Slack 等の要素構造は未検証。アプリ名が title を含む場合、先頭出現の切り出しで誤った名前になり得る。

## 検討した代替案と採用理由

- Why: .app ではなく CLI。理由: 権限挙動が検証済みなのはターミナル起動だけ。.app は Info.plist・署名・再ビルド時の権限失効という未検証事項を増やす。
- Why: key=value ではなく JSON。理由: Foundation Codable で自前パーサが不要になり、壊れた入力もデコーダで検出できる。Windows 側も標準ライブラリで読める。コメント不可は受け入れる。
- Why: NSScreen.main ではなく AX フォーカス窓。理由: アクセサリアプリから見た NSScreen.main の意味は未検証で、AX 権限は捕捉のため既に必要。
- Why: 起動時のみではなくバナーごとに設定を読む。理由: ファイル監視や再読込メニューなしで編集が反映される。
- Why: Swift 1 本ではなく 4 本。理由: 工程ごとに主編集先が分かれ、検証も切り分けられる。少数ファイルの範囲に収まる。

## 工程一覧

番号順に直列実行する。工程の検証コマンドは notify-flash ルートを作業ディレクトリとする。01〜03 は対象 ID 未登録の間、自己テストが終了コード 1。04 はルート Makefile がない間、make が非 0 となる。

| 番号 | 題 | files | 依存 | データ形状 | 検証面 |
|---|---|---|---|---|---|
| [01](plan/process-01.md) | 捕捉＋ビルド土台 | macos/Makefile、macos/main.swift、macos/Capture.swift | なし | `Banner{uuid, appName?}` | cli / --self-test E1〜E6・D1〜D5 |
| [02](plan/process-02.md) | 描画 | macos/Glow.swift、macos/main.swift | process-01 | `[(on: ms, off: ms)]`、`pickScreen(point?, frames)->Int` | cli / --self-test C3・C4・S1・S2 |
| [03](plan/process-03.md) | 設定・メニューバー | macos/Config.swift、macos/main.swift | process-01 | `Config{count:Int, apps:[String:String]}` | cli / --self-test A1〜A6・C1・C2 |
| [04](plan/process-04.md) | 統合・ルート Makefile | Makefile、macos/main.swift | process-01、process-02、process-03 | なし。判定関数のみ | cli / --self-test I1〜I3 と代表 ID |

自己テストの固定入力と期待値を以下に置く。観測値と設計用入力を区別する。

| ID | 入力・条件 → 期待値 |
|---|---|
| E1 | 観測 desc `terminal-notifier、iTerm focusbm, Tool permission requested`、title `iTerm focusbm` → `terminal-notifier` |
| E2 | 観測 desc `terminal-notifier、notify-flash test 1, plain sender`、title `notify-flash test 1` → `terminal-notifier` |
| E3 | 設計用入力。title 空、desc `App、, only body`、body `only body` → `App` |
| E4 | title・body とも空 → nil |
| E5 | title が desc にない → nil |
| E6 | 設計用入力。desc `My Notify、Notify, body`、title `Notify` → `My`。先頭出現の規則を固定 |
| D1 | 同一 UUID で Created / WindowCreated / LayoutChanged → 発光要求 1 |
| D2 | UUID 2 つ → 発光要求 2 |
| D3 | UUID 空 → 発光要求 0 |
| D4 | 同一 UUID が Destroyed 後に再入場 → 発光要求は 1 のまま |
| D5 | 1 回目は抽出失敗、同 UUID の 2 回目で成功 → 発光要求 1 |
| C3 | reduce motion 真 → 点灯 1 回。偽 → 点灯 150ms＋消灯 250ms を count 回 |
| C4 | 幅 6、不透明度 0.8 |
| S1 | 点を含む矩形が 1 枚 → その添字。縦積み 2 画面で AX 座標から NSScreen 座標への変換も確認 |
| S2 | どの画面にも含まれない / 点 nil → 0 |
| A1 | 設定表示名と抽出名が一致 → その色 |
| A2 | 大文字小文字だけ異なる → 一致せず発光しない |
| A3 | apps 空 → 発光しない |
| A4 | ファイルなし → `{"count":3,"apps":{}}` を生成し発光しない |
| A5 | 壊れた JSON → nil、発光しない |
| A6 | 既存ファイルに既定生成を呼ぶ → 内容が変わらない |
| C1 | 2 アプリに別色 → それぞれの色 |
| C2 | count 0 / 11 → 3、5 → 5。全体共通でアプリ別カウンタなし |
| I1 | ON・対象アプリ → 色と count 付き発光要求 |
| I2 | OFF → 発光しない |
| I3 | 設定にないアプリ → 発光しない |

## 終了条件（全体の受入コマンド）

機械検証は次の 1 行が終了コード 0 になること。自己テストだけで実機の AX・描画挙動を確認したとは扱わない。

```sh
make all && macos/notify-flash --self-test E1 E2 E3 E4 E5 E6 D1 D2 D3 D4 D5 C3 C4 S1 S2 A1 A2 A3 A4 A5 A6 C1 C2 R1 I1 I2 I3
```

- （2026-10-10 追加）R1: `rules`（`[{"contains":"…","color":"#RRGGBB"}]`）はタイトル＋本文の部分一致（大文字小文字区別）で、先頭一致を `apps` より優先する。空文字・不正色のルールは無視する。

- (a) executor: human。起動元ターミナルにアクセシビリティ権限を付与後、`macos/notify-flash` を起動して信頼状態になる。
- (b) executor: human。config.json の apps に terminal-notifier を色付きで登録し count を 3 にする。`terminal-notifier -title t -message m` の実バナー 1 件でフォーカス中ディスプレイの縁が設定色で 3 回光り、クリックが下の窓に通る。動きを減らす設定が有効なら 1 回点灯。
- (c) executor: human。複数画面でフォーカスのないディスプレイは光らない。
- (d) executor: human。メニューバーから ON/OFF と設定ファイルを開ける。OFF は点灯中でも即非表示になる。
- (e) executor: human。Slack 等の実アプリ通知で同じ要素構造かを確認する。`-sender` 偽装は使わない。
- (f) executor: human。全画面アプリの Space 上で縁が光る。

## 適用スキル

- `poteto-mode`（全工程。実装担当は着手前に `poteto-mode` skill の SKILL.md を全文読む）
