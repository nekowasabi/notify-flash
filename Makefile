# 既定の `make` は focusbm と同じく、既存プロセスを終了 → 再ビルド → 再起動する。
.DEFAULT_GOAL := relaunch

all:
	$(MAKE) -C macos

relaunch:
	$(MAKE) -C macos app
	@pkill -x notify-flash || true
	@sleep 0.5
	open macos/NotifyFlash.app

.PHONY: all relaunch
