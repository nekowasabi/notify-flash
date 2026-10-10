# 既定の `make` は focusbm と同じく、既存プロセスを終了 → 再ビルド → 再起動する。
DOTNET ?= dotnet
# Why: WSL の mise は .NET 10 SDK のみで 8.0 ランタイムが無い。net8.0 の成果物を動かすため前方互換にする（focusbm と同じ）。
export DOTNET_ROLL_FORWARD ?= LatestMajor
# Why: UNC（\\wsl.localhost）ではなくローカルディスクから起動する。UNC 起動の exe は AV に誤検知されやすい。
RELEASE_DIR ?= /mnt/c/takeda/tools/notify-flash

ifeq ($(PC),wsl)
.DEFAULT_GOAL := release
else
.DEFAULT_GOAL := relaunch
endif

all:
	$(MAKE) -C macos

relaunch:
	$(MAKE) -C macos app
	@pkill -x notify-flash || true
	@sleep 0.5
	open macos/NotifyFlash.app

# Why: framework 依存のフォルダ publish にする。単一ファイルの自己展開は AV にドロッパーと誤検知される。
# Why: RELEASE_DIR は消さない。同居する config.json と notify-flash.log を保つため。
release:
	mkdir -p $(RELEASE_DIR)
	# Why: 起動中の NotifyFlash.exe が DLL をロックし publish のコピーが Access denied になるため先に止める
	-taskkill.exe /IM NotifyFlash.exe /F >/dev/null 2>&1
	$(DOTNET) publish windows/NotifyFlash.csproj -c Release -r win-x64 --self-contained false \
		-p:PublishSingleFile=false \
		-p:DebugType=None \
		-p:CopyOutputSymbolsToPublishDirectory=false \
		-o $(RELEASE_DIR)
	# Why: 通知の購読にはパッケージ ID が要る。exe を RELEASE_DIR に置いたまま sparse package として登録する
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$$(wslpath -w windows/register-package.ps1)" \
		-PackageDir "$$(wslpath -w windows/package)" -ExternalLocation "$$(wslpath -w $(RELEASE_DIR))"
	# Why: 冒頭の taskkill で止めたアプリを戻す。cwd を RELEASE_DIR にして UNC ではなくローカルディスクから起動する
	cd $(RELEASE_DIR) && powershell.exe -NoProfile -Command "Start-Process -FilePath .\NotifyFlash.exe"

.PHONY: all relaunch release
