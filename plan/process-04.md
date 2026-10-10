# Process 04: 統合・ルート Makefile

## goal

捕捉 → 設定照合 → ON/OFF 判定 → フォーカス窓の画面選択 → 発光を結線する。設定はバナーごとに読み、ON・対象アプリのときだけ色と全体共通 count 付きの発光要求を渡す。判定を純粋関数にして I1 は ON・対象アプリで発光要求、I2 は OFF で発光なし、I3 は設定にないアプリで発光なしを検証する。データ形状の追加はなく判定関数のみ。

ルート Makefile は `make -C macos` に委譲して macOS 本体をビルドする。ルート Makefile がない間は make が非 0 になる。Windows ターゲットは作らない。自己テストは AX 権限確認と NSApplication 生成より前に分岐し、AX と実際の ~/.config を触らない。protocol による 1 実装だけの抽象化は追加しない。

## files

- Makefile
- macos/main.swift

## verify

```sh
make
test -x macos/notify-flash
cd macos && ./notify-flash --self-test E1 D1 C3 S1 A1 I1 I2 I3
cd macos || exit 2; rg -n '^protocol ' --glob '*.swift' .; test $? -eq 1
```

## depends_on

process-01, process-02, process-03
