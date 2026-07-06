# gdrive-resync

**Cleanly restart Google Drive for desktop on macOS to fix Finder sync stalls — one command, zero data loss.**

On macOS 26 ("Tahoe") in particular, Google Drive for desktop can silently stop
reflecting changes in Finder. Quitting from the menu bar often isn't enough,
because wedged helper processes survive. `gdrive-resync` does a *thorough*
stop-and-restart and verifies that syncing actually came back to life.

> It restarts **processes only**. It never touches your files or the local
> Drive cache — nothing is deleted.

---

## The problem

Since macOS 12.3, Google Drive for desktop syncs through Apple's **File Provider**
framework and mounts under `~/Library/CloudStorage/GoogleDrive-*`. On Tahoe the
auth/sync engine can **wedge**: the client repeatedly fails to refresh its OAuth
access token while the OS network is otherwise fine, so remote changes stop
arriving and Finder shows stale contents.

The fingerprint, straight from the DriveFS log:

```
E ... phenotype_http_client.cc:216:RefreshAccountIdsAndTokens
      Failed to refresh access token with status: DEADLINE_EXCEEDED: BlockingQueue Pop timed out: 1m
```

A plain menu-bar **Quit** leaves helper processes (`DFSFileProviderExtension`,
`FinderSyncExtension`, renderer, `crashpad_handler`) running, so relaunching
re-attaches to the same wedged state. You have to stop **all** of them.

## What it does

1. Asks Google Drive to quit gracefully (AppleScript).
2. Escalates to `SIGTERM`, then `SIGKILL`, for **every** process whose executable
   lives inside `/Applications/Google Drive.app` — matched by executable path, so
   unrelated processes are never touched.
3. Relaunches Google Drive.
4. Watches the DriveFS log and confirms the sync pipeline is alive again
   (`OnChangeNotificationReceived` / `Successfully signaled changes`).

## Quick start

```bash
git clone https://github.com/Yayutom/gdrive-resync.git
cd gdrive-resync
chmod +x restart-google-drive.sh

./restart-google-drive.sh            # stop + start + verify
```

Prefer double-clicking in Finder? Copy it to a `.command` file:

```bash
cp restart-google-drive.sh ~/Desktop/Fix-Google-Drive.command
chmod +x ~/Desktop/Fix-Google-Drive.command
```

## Usage

| Command | What it does |
|---|---|
| `./restart-google-drive.sh` | Stop, start, and verify recovery (default) |
| `./restart-google-drive.sh --diagnose` | Report auth/sync health from the logs — no restart |
| `./restart-google-drive.sh --status` | List running Google Drive processes — no restart |
| `./restart-google-drive.sh --no-verify` | Restart but skip the log check |
| `./restart-google-drive.sh --help` | Show help |

`--diagnose` is a good first step — it tells you whether you're actually hitting
the token-refresh wedge before you restart anything.

## Requirements

- macOS (uses File Provider — macOS 12.3+; built for and tested on macOS 26 Tahoe)
- Google Drive for desktop installed at `/Applications/Google Drive.app`
- No dependencies beyond the system shell

## If it keeps coming back

A one-off wedge clears with a restart. If `--diagnose` keeps showing
token-refresh failures after restarting, the auth session itself is stale — do a
full re-sign-in: **Google Drive settings (gear) → your account → Disconnect
account → sign in again**. Shared Drives are stream-only, so this re-fetches the
index without re-downloading file contents.

## Safety

- Signals only Google Drive's own bundle processes; matched by executable path.
- Never deletes, moves, or edits any file, and never clears the DriveFS cache.
- Read-only modes (`--status`, `--diagnose`) make no changes at all.

---

## 日本語

macOS 26（Tahoe）で **Googleドライブ（デスクトップ版）の更新がFinderに反映されなくなる**
不具合を、ワンコマンドで復旧するツールです。メニューバーの「終了」では詰まったヘルパー
プロセスが生き残り直らないことがあるため、**アプリの全プロセスを確実に停止してから再起動**し、
同期が復活したかログで検証します。

- **ファイルやローカルキャッシュには一切触れません**（消しません）。プロセスを再起動するだけです。
- 根本原因は、OSのネットは正常なのに Drive 内部の **OAuthトークン更新が詰まる**こと
  （DriveFSログの `Failed to refresh access token`）。この状態だとサーバからの変更通知が
  止まり、Finder が古いまま固まります。

### 使い方

```bash
./restart-google-drive.sh            # 停止→再起動→復旧検証（既定）
./restart-google-drive.sh --diagnose # ログから認証/同期の状態を診断（再起動しない）
./restart-google-drive.sh --status   # 稼働中プロセス表示（再起動しない）
```

まず `--diagnose` で「本当にトークン更新の詰まりか」を確認してから再起動するのがおすすめです。
再起動しても `--diagnose` にトークン失敗が出続ける場合は、Drive設定 → アカウントの接続を解除 →
再サインイン（共有ドライブはストリーム型なので中身の再DLは不要）。

---

## License

MIT — see [LICENSE](LICENSE).
