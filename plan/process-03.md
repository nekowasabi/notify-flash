# Process 03: 設定・メニューバー

## goal

設定ファイルの読込・既定生成・照合と、メニューバーの操作を実装する。macos/Config.swift を新設し、macos/main.swift に NSStatusItem を足す。

- 設定ファイル: `~/.config/notify-flash/config.json`。形 `{"count": 3, "apps": {"terminal-notifier": "#FF8800"}}`。Foundation の JSONDecoder（Codable）で読む。読込はバナーごと（ファイル監視・再読込メニューなし）。
- 既定生成: 起動時にファイルが無ければ `{"count": 3, "apps": {}}` を作る。既存ファイルは決して上書きしない。
- 異常系: 壊れた JSON は stderr に 1 行出して nil を返し発光しない。count は 1〜10 以外なら 3（全体共通。アプリ別カウンタなし）。色は `#RRGGBB` 以外ならそのアプリ項目を無視。表示名は大文字小文字を区別する完全一致。apps が空なら発光しない。
- 型: `Config{count:Int, apps:[String:String]}`。protocol は置かない。
- メニューバー: NSStatusItem に「ON/OFF 切替」「設定ファイルを開く（NSWorkspace.open。無ければ既定を作ってから開く）」「終了」。ON/OFF はメモリ上の状態のみ（起動時 ON、永続化なし）。OFF にしたら点灯中のオーバーレイも即非表示（process-02 の入口を呼ぶ）。
- 自己テスト: Config.swift に自分の自己テスト関数を置き、main.swift の `--self-test` 分岐から A1〜A6 C1 C2 を振り分ける。失敗は `precondition` か明示 `exit(1)` で検出し、`assert(` は使わない。自己テストは AX を呼ばず、~/.config も触らず一時ディレクトリを使う。
  - A1: 設定の表示名と抽出名が一致 → その色
  - A2: 大文字小文字だけ違う → 一致しない（発光しない）
  - A3: apps が空 → 発光しない
  - A4: ファイルが無い → `{"count":3,"apps":{}}` を作成し、発光しない
  - A5: 壊れた JSON → nil（発光しない）
  - A6: 既存ファイルがある状態で既定生成を呼ぶ → 内容が変わらない
  - C1: 2 アプリに別色 → それぞれの色を返す
  - C2: count 0 / 11 → 3、5 → 5

## files

- `macos/Config.swift`
- `macos/main.swift`

## verify

```sh
cd macos && make
cd macos && ./notify-flash --self-test A1 A2 A3 A4 A5 A6 C1 C2
rg -q 'NSStatusItem' macos/main.swift
cd macos || exit 2; rg -n 'assert\(' --glob '*.swift' .; test $? -eq 1
```

## depends_on

process-01
