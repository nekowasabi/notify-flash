# Process 01: 捕捉＋ビルド土台

## goal

macos/ を新設し、`swiftc -O *.swift -o notify-flash` のビルドと `--self-test <ID>...` の入口を作る。未登録 ID または失敗は終了コード 1、全通過は 0、ID 無指定は 2。分岐は AX 権限確認と NSApplication 生成より前に置き、AX を呼ばず実際の ~/.config を触らない。自己テスト関数は各 Swift ファイルに置き main.swift が振り分ける。失敗検出は precondition または明示 exit(1) とし assert は使わない。

AX で com.apple.notificationcenterui の AXWindowCreated / AXCreated / AXLayoutChanged / AXUIElementDestroyed を購読し、AXSubrole=AXNotificationCenterBanner の AXDescription を名前指定で取得する。子 AXStaticText の title / body の AXValue を使ってアプリ名を切り出す。title が空なら body を選び、AXDescription 内の先頭出現より前から末尾の句読点・空白を除く。両方空・検索失敗・結果が空なら nil。読点分割へ戻さず PoC の全属性ダンプも持ち込まない。

UUID の AXIdentifier が空なら発光要求 0。抽出成功後に初めて既見を記録し、直近 64 件を FIFO で保持する。Destroyed で削除しない。データ形状は Banner{uuid, appName?}。E1〜E6 / D1〜D5 の入力と期待値は PLAN.md を使う。対象 ID が未登録の間は自己テストを終了コード 1 にする。Swift の protocol を追加しない。

## files

- macos/Makefile
- macos/main.swift
- macos/Capture.swift

## verify

```sh
cd macos && make
cd macos && ./notify-flash --self-test E1 E2 E3 E4 E5 E6 D1 D2 D3 D4 D5
cd macos || exit 2; rg -n 'assert\(' --glob '*.swift' .; test $? -eq 1
cd macos || exit 2; rg -n '^protocol ' --glob '*.swift' .; test $? -eq 1
```

## depends_on

なし
