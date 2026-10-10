# FINDINGS: notify-flash PoC（2026-10-10）

「検証済み」はこの環境で実行して出力を確認したもの。それ以外は「未検証」とし、根拠の種類を書く。

## 0. 環境（検証済み）

- `sw_vers` の出力は `ProductVersion: 26.6.2`、`BuildVersion: 25G83`。
- `pgrep -l NotificationCenter` の出力は `588 NotificationCen` と `1219 UserNotificatio`。
- PoC が bundle id `com.apple.notificationcenterui` で見つけたプロセスは pid 588、名前は「通知センター」。
- `swiftc` は Apple Swift 6.3.3、target は arm64-apple-macosx26.0。`make` は警告もエラーも無く通った。

## 1. AX 権限と購読（検証済み）

- `./notify-flash-poc --seconds 5`（プロンプトなし）の出力は `AX trusted: true (prompt=false)`。このセッションを起動したターミナルには、既にアクセシビリティ権限がある。ダイアログは出ていない。
- 購読した `AXWindowCreated`、`AXCreated`、`AXLayoutChanged`、`AXUIElementDestroyed` は、4 つとも `AXError 0` を返した。
- バナーが無いとき、アプリ要素は `AXWindows=<array 0>` で、子はメニューバーだけ。

## 2. バナーからアプリ識別子が取れるか

### 取れたもの（検証済み、run3.txt 17 行目）

バナーは次の階層にあった。

```
AXWindow（AXSubrole="AXSystemDialog"、AXTitle="Notification Center"、画面全体の大きさ）
> AXGroup（AXHostingView）
> AXGroup
> AXScrollArea
> AXGroup（AXSubrole="AXNotificationCenterBanner"）
```

バナー要素の属性は次のとおり。

- `AXDescription="terminal-notifier、iTerm focusbm, Tool permission requested"`
  - この属性は `AXUIElementCopyAttributeNames` の一覧に出てこない。名前を指定して直接問い合わせると値が返る。
- `AXAttributedDescription` は上と同じ文字列で、こちらは一覧に出る。
- `AXIdentifier="B0A4A44B-AD5E-4C06-8AE1-0BA60AA5944A"`
  - バナーごとの UUID。1 件のバナーで発生した全イベントで同じ値だった。
- 子要素は 2 つの `AXStaticText`。
  - `AXIdentifier="title"` の要素は `AXValue="iTerm focusbm"`。
  - `AXIdentifier="body"` の要素は `AXValue="Tool permission requested"`。
- 操作は `AXPress`、「詳細を表示」、「表示」、「閉じる」。

### 取れなかったもの（検証済み）

- `AXStackingIdentifier` と `AXBundleIdentifier` は、全要素に問い合わせて全部 nil だった（`rg -c "Stacking|BundleIdentifier" run3.txt` は 0 件）。
- 確かめたのはこの 2 つの名前だけである。「バンドル ID を返す属性はどこにも無い」とまでは言えない。

### 送信元の名前について（検証済み）

`AXDescription` の先頭に出るのは、通知を投稿したプロセスの名前である。run3 では `terminal-notifier` だった。本当の発信元（iTerm / Claude Code）は本文のテキストにしか出ていない。terminal-notifier 経由の通知は、すべて同じアプリとして色分けされる。

### 未検証の点

- **切り出しの規則（推論）。** 観測した書式は `<アプリ名>、<タイトル>, <本文>` だった。アプリ名の後ろが日本語の「、」、本文の前が ASCII の `, ` である。「最初の『、』より前をアプリ名とする」は、ローカライズされた区切り文字からの推測にすぎない。英語ロケールの場合、アプリ名に「、」を含む場合、タイトルが無い場合は確かめていない。
- **Ghostty のバナー（run2）のアプリ名。** このときは属性付き文字列を値として出していなかったので、アプリ名は不明。

### イベントの形（裏付けあり。破棄後の要素は読めない）

1 件のバナーで次のイベントが届いた。

1. `AXCreated`（窓ごと）
2. `AXWindowCreated`
3. `AXLayoutChanged` が 2〜3 回（スライドイン中で x 座標が変わる）
4. `AXUIElementDestroyed` が数回

バナーが出て消えるまでの時間は 2 回とも約 4〜5 秒だった（00:56:04 → 00:56:08〜09、00:56:58 → 00:57:03）。

本体では、`AXSubrole == "AXNotificationCenterBanner"` の要素の `AXIdentifier` で重複を除き、1 件のバナーで 1 回だけ発光させる。

### 追加観測（2026-10-10 01:27、手動実行）

- `terminal-notifier -title "notify-flash test 1" -message "plain sender"` → `AXDescription="terminal-notifier、notify-flash test 1, plain sender"`。英字のみのタイトル・本文でも区切りは `、` と `, `（区切りはシステム言語 ja に依存、コンテンツ言語には依存しない）。
- 同じ呼び出しで続けて送った `-sender com.tinyspeck.slackmacgap` / `-sender com.apple.Terminal` の 2 件は、コマンドが 19 秒以上返らず中断したため、バナーの有無は未確認（ログは test 1 の破棄で切れている）。`-sender` 偽装は検証手段として当面使わない。原因は未検証。
- **アプリ名の切り出し規則（差し替え）**: 区切り文字（`、` / `, `）に依存せず、子要素 `AXIdentifier="title"` の `AXValue` を `AXDescription` 内で検索し、その手前（末尾の句読点・空白を除く）をアプリ名とする。手元の 4 サンプル（`iTerm focusbm` / Ghostty 2 件 / `notify-flash test 1`）すべてで `terminal-notifier` が得られる。title が空なら `body` の `AXValue` で同じ処理をする。これでロケール依存の未検証は消え、残るのは「他アプリでも同じ要素構造か」のみ。
- 1 件の寿命は 01:27:49（AXCreated）→ 01:27:55（Destroyed ×4）の約 6 秒。消える直前の `AXLayoutChanged` では x が 1444 まで動く（右へスライドアウト前の再配置）。

### 再現手順

```
cd /Users/takets/repos/notify-flash/poc && make
./notify-flash-poc --seconds 120 | tee dump.txt
rg -o 'AXDescription="[^"]*"' dump.txt
```

## 3. 集中モード／通知スタイル「なし」は拾えない（未検証、推論。2026-10-10 利用者判断でスコープ外）

AX は画面に描かれた UI しか見ない。抑止された通知はバナー窓を作らないので、AX 通知も届かないはずである。

確認するには次のどちらかで通知を出し、PoC に `AXNotificationCenterBanner` が出ないことを見る。

- 対象アプリの通知スタイルを「なし」にする。
- 集中モードをオンにし、許可していないアプリから通知を出す。

逆向きの誤検知にも注意が要る。通知センターのパネルを開くと、過去の通知が要素として作られる可能性がある。本体では、サブロールと出現位置でパネルとバナーを区別できるかを確かめる。

## 4. 縁発光の初期値（未検証、推定）

| 項目 | 初期値 | 根拠 |
|---|---|---|
| 幅 | 6pt | 周辺視野で気づけて、内容をほぼ隠さない。経験則のみ |
| 1 回の発光 | 点灯 150ms＋消灯 250ms（周期 400ms、2.5Hz） | WCAG 2.3.1 の「1 秒に 3 回を超えて点滅しない」を下回る |
| 回数 | 3 回（計 1.2 秒） | 実測したバナー寿命（約 4〜5 秒）の中に収まる |
| 不透明度 | 最大 0.8、アプリ別の色 | 背景の明暗によらず見えるようにする |

`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` が true のときは、1 回だけ点灯する方式に切り替える案がある。
