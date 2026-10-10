# Process 02: 描画

## goal

透明・クリック貫通・最前面・全 Space のオーバーレイで画面の縁を点滅させる。macos/Glow.swift を新設し、点滅スケジュールと画面選択を純粋関数にして自己テストする。

- オーバーレイ: 全画面サイズの NSWindow（borderless、isOpaque=false、backgroundColor=.clear、ignoresMouseEvents=true、level=.screenSaver、collectionBehavior に canJoinAllSpaces と fullScreenAuxiliary）。縁に幅 6pt・不透明度 0.8・アプリ色の枠を描く。幅・時間・不透明度は定数で、推定値であることをソースコメントに書く。
- 点滅: 点灯 150ms＋消灯 250ms を count 回。accessibilityDisplayShouldReduceMotion が真なら点灯 1 回。スケジュールは純粋関数 `[(on: ms, off: ms)]` を返し、待機でランループを止めず Timer / asyncAfter で回す。点灯中に新しい要求が来たら古いタイマーを世代番号で無効化し、新しい色で最初からやり直す。OFF にされたら点灯中のオーバーレイも即非表示にできる入口を持つ。
- 画面選択: AXUIElementCreateSystemWide → AXFocusedApplication → AXFocusedWindow → AXPosition / AXSize の中心点。AX 座標（主画面左上原点・下向き）を NSScreen 座標（左下原点）へ `y = 主画面高さ − y` で変換し、その点を含む NSScreen を選ぶ。純粋関数 `pickScreen(point: CGPoint?, frames: [CGRect]) -> Int` は、含む画面が無い・点が取れないとき 0（主画面 = NSScreen.screens[0]）を返す。
- 手動発光: `notify-flash --flash-test '#RRGGBB'` は上の画面選択で 1 回分の点滅を出して終了する（人手確認用。AX 権限が無い場合は主画面）。
- 自己テスト: Glow.swift に自分の自己テスト関数を置き、main.swift の `--self-test` 分岐から C3 C4 S1 S2 を振り分ける。失敗は `precondition` か明示 `exit(1)` で検出し、`assert(` は使わない。自己テストは AX を呼ばない。
  - C3: reduce motion 真 → 点灯 1 回 / 偽 → (150ms 点灯, 250ms 消灯) × count
  - C4: 幅 6、不透明度 0.8
  - S1: 点を含む矩形が 1 枚 → その添字（AX 座標から NSScreen 座標への変換関数も、縦積み 2 画面の入力で同じ ID 内で確認）
  - S2: どれにも含まれない / 点 nil → 0

## files

- `macos/Glow.swift`
- `macos/main.swift`

## verify

```sh
cd macos && make
cd macos && ./notify-flash --self-test C3 C4 S1 S2
rg -q 'ignoresMouseEvents' macos/Glow.swift
rg -q 'fullScreenAuxiliary' macos/Glow.swift
cd macos || exit 2; rg -n 'assert\(' --glob '*.swift' .; test $? -eq 1
```

## depends_on

process-01
