# notify-flash PoC: NotificationCenter の AX ダンプ

通知バナーが出たとき、NotificationCenter プロセス（`com.apple.notificationcenterui`）の AX ツリーからアプリ識別子が読めるかを確かめる使い捨ての CLI。製品コードではない。

## ビルド

```sh
cd /Users/takets/repos/notify-flash/poc
make            # swiftc -O main.swift -o notify-flash-poc
```

Xcode プロジェクトと外部依存は無い。Swift 6.3.3（macOS 26.6.2）で警告なしにビルドできることを確認済み。

## 権限付与

AX 権限は実行バイナリではなく、起動元のターミナルアプリ（Terminal / iTerm2 / Ghostty など）に紐づく。

1. 権限の状態だけ見る（ダイアログは出ない）。

   ```sh
   ./notify-flash-poc --seconds 1
   ```

   `AX trusted: false` なら次へ進む。`true` なら手順 3 へ進む。
2. 次のどちらかで付与する。
   - `./notify-flash-poc --prompt` を実行すると、システムのダイアログが出る。そこから設定を開く。
   - システム設定 > プライバシーとセキュリティ > アクセシビリティ を開き、使っているターミナルアプリをオンにする。
   
   付与したらターミナルアプリを終了して開き直す。
3. もう一度 `./notify-flash-poc --seconds 1` を実行し、`AX trusted: true` と出ることを確かめる。

## 実行

```sh
./notify-flash-poc --seconds 120 | tee dump.txt   # 120 秒待ち受けて終了
./notify-flash-poc | tee dump.txt                 # Ctrl-C まで待ち受け
```

待ち受け中に、別のアプリから通知を出す（メールやメッセージを自分宛てに送る、カレンダーで 1 分後のイベントを作る、など）。`osascript -e 'display notification ...'` でも出せるが、初回は通知許可のダイアログが出ることがある。

出力の読み方は次のとおり。

- `=== initial tree` は起動時点の NotificationCenter の窓。バナーが無ければ `AXWindows=<array 0>` だけが出る。
- `subscribe <通知名>: AXError 0` は購読成功。0 以外なら `AXError` の値を見る（-25211 は API 無効すなわち権限なし、-25207 は未対応の通知、-25204 は相手プロセスが応答しない。値は SDK の `AXError.h` による）。
- `=== <時刻> AXWindowCreated` などの行が、受信した AX 通知。その下に、通知を受けた要素から下の木が出る。各行は `AXUIElementCopyAttributeNames` が返した全属性で、文字列・数値・真偽値・座標はそのまま、他は型名だけを出す。
- バナー要素は `AXSubrole="AXNotificationCenterBanner"` の行。macOS 26.6.2 では、その行の `AXDescription` が `"<アプリ表示名>、<タイトル>, <本文>"` だった（例 `"terminal-notifier、iTerm focusbm, Tool permission requested"`）。`AXDescription` は属性名一覧に出てこないため、PoC が名前を指定して直接問い合わせている。

```sh
rg -o 'AXDescription="[^"]*"' dump.txt
```

## 対象プロセスの変更

`main.swift` 先頭の `ncBundleID` を書き換える。OS 更新でバナーを描くプロセスが変わったときだけ使う。
