# 腳本

每支腳本都對應 [遷移指南](../docs/guide.md) 裡的一個步驟。先把 [`zeabur-lib.sh`](zeabur-lib.sh) 裡的 `'<...>'` 換成自己的值；每支腳本開頭用 `require` 檢查自己需要的設定，沒填就停。

## 一覽

「會改變」欄是腳本會動到的東西；寫「唯讀」的可以放心重跑。

| 檔案 | 在哪裡跑 | 做什麼 | 會改變 |
| --- | --- | --- | --- |
| [`zeabur-lib.sh`](zeabur-lib.sh) | 被 source | 共用設定；固定版本的 Zeabur CLI、去掉 CRLF 的 `zexec`、`gssh`／`gscp`、`require` | — |
| [`fetch-file.sh`](fetch-file.sh) | 被 source | `fetch_file`：從 Zeabur 容器分片取回檔案，驗 SHA-256，可重跑 | 本機檔案 |
| [`zeabur-inventory.py`](zeabur-inventory.py) | 本機 | 列出帳號下所有專案、服務、狀態、網域、預定刪除時間 | 唯讀 |
| [`zeabur-git-trigger.py`](zeabur-git-trigger.py) | 本機 | 把服務的 Git 自動部署指向某個分支（停用／恢復） | Zeabur 設定 |
| [`sync-env.sh`](sync-env.sh)＋[`build-app-env.py`](build-app-env.py) | 本機 | 環境變數分類後寫進 Secret Manager；加密金鑰另存並比對指紋 | Secret Manager |
| [`sync-db.sh`](sync-db.sh)＋[`counts.sql`](counts.sql)＋[`restore-on-host.sh`](restore-on-host.sh) | 本機＋VM | dump、取回；VM 進 standby、換新的資料目錄（舊的改名保留）、還原、清 Redis；每張表筆數比對 | VM 上的資料庫 |
| [`sync-assets.sh`](sync-assets.sh)＋[`copy-assets.js`](copy-assets.js) | Zeabur 的 API 容器 | MinIO 的物件複製到 GCS，key 不變，可重跑 | GCS |
| [`verify.sh`](verify.sh) | 本機 | 切換前的最後驗證；**第三項要補上專案自己的檢查** | 唯讀 |
| [`deploy.sh`](deploy.sh) | VM（`/srv/app`） | secrets → 清舊 image → pull → migrate → rollout → worker → 清舊 image | 正式環境 |
| [`release.sh`](release.sh) | 本機 | Cloud Build 建置 HEAD，再登入 VM 執行 `deploy.sh`；`--deploy-only <tag>` 回滾 | 正式環境 |
| [`backup.sh`](backup.sh) | VM（systemd timer） | 每晚 `pg_dump` 上傳到只能寫入的 bucket | GCS |
| [`probe.sh`](probe.sh) | 本機 | 部署期間持續打網址，統計失敗數 | 唯讀 |
| [`cutover.sh`](cutover.sh) | 本機 | 正式切換，要加 `--confirm` | Zeabur、GCP |
| [`retire-zeabur-frontends.sh`](retire-zeabur-frontends.sh) | 本機 | 舊前台換成 302 轉址，等轉址生效 | Zeabur |
| [`verify-admin-block.sh`](verify-admin-block.sh) | 本機 | 確認後台 API 只能從 Access 後面進去 | 唯讀 |
| [`fetch-minio-data.sh`](fetch-minio-data.sh) | 本機 | 最後封存：逐檔取回 MinIO 的 `/data` | 本機檔案 |
| [`final-archive.sh`](final-archive.sh) | 本機 | 最後封存：加密、金鑰進 Secret Manager、上傳 Archive bucket、下載解密驗證 | Secret Manager、GCS |
| [`cloudflare-access.py`](cloudflare-access.py) | 本機 | 建 email 一次性密碼登入與後台的 Access 應用 | Cloudflare |

設定範本在 [`../templates/`](../templates/)：`compose.example.yaml`、`cloudbuild.example.yaml`、`trust-proxy.ts`、`systemd/`、`zeabur-redirect/`。放到自己專案時，VM 上的檔案全部平放在同一個目錄（`release.sh` 預設是 `deploy/host/`）：`compose.yaml`、`deploy.sh`、`backup.sh`、`db-backup.service`、`db-backup.timer`。

`cutover.sh` 在動到 Zeabur 之前會先檢查所有設定都填了、`verify.sh` 的第三項（專案自己的檢查）也補上了，任何一項沒做就不會開始。

## 依階段的使用順序

| 階段 | 腳本 |
| --- | --- |
| Phase 0 準備 | `zeabur-inventory.py`（看清楚帳號下有什麼） |
| Phase 2 讓 VM 跑起來 | `release.sh`＋`deploy.sh`＋`backup.sh`；部署時開 `probe.sh`；`cloudflare-access.py`；`verify-admin-block.sh` |
| Phase 3 資料搬移與演練 | `sync-env.sh` → `sync-db.sh` → `sync-assets.sh` → `verify.sh`，完整跑兩輪：第二輪就是切換的演練。`cutover.sh` 會暫停正式環境，不能拿來演練 |
| Phase 4 正式切換 | `cutover.sh --confirm` |
| Phase 5 下線 | `fetch-minio-data.sh` → `final-archive.sh` → `zeabur-inventory.py` → 刪除服務 → 再跑一次 `zeabur-inventory.py` |

## 前置需求

- 本機：bash、python3、Node.js（`npx zeabur@0.24.0`）、gcloud、gpg、openssl、`pg_restore`（libpq）。
- macOS 的預設 shell 是 zsh：腳本都用 `bash` 執行，共用檔用 bash `source`。
- Zeabur CLI 的登入過期時執行 `npx zeabur@0.24.0 auth login`；在網站上登入不會更新 CLI 的 token。
- gcloud：每支腳本都明確帶 `--project` 與 `--zone`，不依賴預設值。

## Cloudflare Access

1. 帳號擁有者在 Cloudflare dashboard 開通 Zero Trust：取 team 名稱、選 Free 方案並完成結帳（0 元也要按最後確認，可能要先綁信用卡）。這一步 API 做不到。
2. 建一個 API token：Access: Apps and Policies → Edit、Access: Organizations, Identity Providers, and Groups → Edit，Account Resources 只選這個帳號，設幾天後過期。`cloudflared tunnel login` 產生的憑證管不到 Access。
3. 用隱藏輸入存進 macOS Keychain（會問兩次）：

   ```bash
   security add-generic-password -U -a "$USER" -s cloudflare-access-token -w
   ```

4. 改好 [`cloudflare-access.py`](cloudflare-access.py) 開頭的帳號 ID、網域與允許名單，執行它，再用無痕視窗確認：未登入會被導到 `<team>.cloudflareaccess.com`，允許名單外的 email 收不到驗證碼。
5. Access 只擋住「這個網域」。後台呼叫的 API 若在另一個公開網域，照 [`compose.example.yaml`](../templates/compose.example.yaml) 的 `admin-api` 路由把它收到後台網域底下，讓公開網域拒絕後台路徑，再跑 [`verify-admin-block.sh`](verify-admin-block.sh)。

## 安全

- 含 secret 的檔案只放在 `umask 077` 的暫存目錄，用完就刪；金鑰不印到螢幕、不寫進 shell 歷史。
- 會改變正式環境的腳本先在 staging 跑過。`cutover.sh` 沒有 `--confirm` 不會動作。
- 刪除前一律先確認對象：`zeabur-inventory.py` 看清楚，刪除用 ID 不用名稱。
