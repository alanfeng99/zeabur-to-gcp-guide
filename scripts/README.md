# 腳本

每支腳本都對應 [遷移指南](../docs/guide.md) 裡的一個步驟。先把 [`zeabur-lib.sh`](zeabur-lib.sh) 裡的 `'<...>'` 換成自己的值；每支腳本開頭用 `require` 檢查自己需要的設定，沒填就停。

## 一覽

「會改變」欄是腳本會動到的東西；寫「唯讀」的可以放心重跑。

| 檔案 | 在哪裡跑 | 做什麼 | 會改變 |
| --- | --- | --- | --- |
| [`zeabur-lib.sh`](zeabur-lib.sh) | 被 source | 共用設定；固定版本的 Zeabur CLI、去掉 CRLF 的 `zexec`、`gssh`／`gscp`、`require` | — |
| [`fetch-file.sh`](fetch-file.sh) | 被 source | `fetch_file`：從 Zeabur 容器分片取回檔案，驗 SHA-256，可重跑 | 本機檔案 |
| [`zeabur-discover.py`](zeabur-discover.py) | 本機 | 盤點一個專案：服務、image、volume 與用量、網域、Git 自動部署、環境變數的名稱（不讀值）；適用性檢查；建議的 `zeabur-lib.sh` 設定 | 唯讀 |
| [`zeabur-inventory.py`](zeabur-inventory.py) | 本機 | 列出帳號下所有專案、服務、狀態、網域、預定刪除時間 | 唯讀 |
| [`check-placeholders.py`](check-placeholders.py) | 本機 | 列出還沒換掉的 `<...>` 與 example.com；apply 前、第一次部署前、切換前各跑一次 | 唯讀 |
| [`init-secrets.sh`](init-secrets.sh) | 本機（自己的終端機） | `app-env` 與 `encryption-key` 的第一個版本：隨機的資料庫密碼、選用的 GCS HMAC 金鑰、staging 用的加密金鑰；已有版本就跳過 | Secret Manager、HMAC 金鑰 |
| [`setup-tunnel.sh`](setup-tunnel.sh) | 本機 | 建後台用的 Cloudflare tunnel、把後台網域指過去、token 寫進 Secret Manager（先跑 `cloudflare-access.py`） | Cloudflare、Secret Manager |
| [`set-env.sh`](set-env.sh) | 本機（自己的終端機） | 替 `app-env` 補上 app 開機就要的變數（staging 值）：隱藏輸入，或 `--random` 隨機產生 | Secret Manager |
| [`zeabur-git-trigger.py`](zeabur-git-trigger.py) | 本機 | 把服務的 Git 自動部署指向某個分支（停用／恢復）；`zeabur-lib.sh` 的 `git_trigger` 在沒有自動部署時跳過 | Zeabur 設定 |
| [`zeabur-status.py`](zeabur-status.py) | 本機 | 印出服務狀態，全部 RUNNING 才以 0 結束 | 唯讀 |
| [`zeabur-api-check.py`](zeabur-api-check.py) | 本機 | 確認上面幾支 Python 腳本的查詢、Zeabur CLI 背後的 restart／redeploy／suspend 用到的欄位與參數都還在（introspection，只讀 schema）；`cutover.sh` 動到 Zeabur 之前也會跑 | 唯讀 |
| [`sync-env.sh`](sync-env.sh)＋[`build-app-env.py`](build-app-env.py) | 本機 | 每個 app 服務的環境變數合併、分類後寫進 Secret Manager（沿用 `init-secrets.sh` 的資料庫密碼與 GCS 金鑰）；加密金鑰另存並比對指紋。HOLD 的憑證（會對外發訊息的）只在 `--live` 時放正式值。之後要 `release.sh --deploy-only` 才生效 | Secret Manager |
| [`sync-db.sh`](sync-db.sh)＋[`counts.sql`](counts.sql)＋[`restore-on-host.sh`](restore-on-host.sh) | 本機＋VM | dump、取回；VM 進 standby、換新的資料目錄（舊的改名保留）、還原、清 Redis；每張表筆數比對。`--dump-only` 只取回 dump（Phase 0 的備份）。切換後（有 live 標記）拒絕執行 | VM 上的資料庫 |
| [`sync-volume.sh`](sync-volume.sh) | 本機＋VM | app 服務自己的 volume：容器內打包、取回、驗 SHA-256、解開到 VM 的資料碟，兩邊比對檔案數。`--fetch-only` 只取回 | VM 上的目錄 |
| [`sync-assets.sh`](sync-assets.sh)＋[`copy-assets.js`](copy-assets.js) | Zeabur 的 API 容器 | MinIO 的物件複製到 GCS，key 不變，可重跑。`--create-key`／`--delete-key` 建立／刪除暫時 HMAC 金鑰（只存在 `$WORK/dest-hmac.json`，不顯示） | GCS、HMAC 金鑰 |
| [`verify.sh`](verify.sh) | 本機 | 切換前的最後驗證；**第三項要補上專案自己的檢查** | 唯讀 |
| [`deploy.sh`](deploy.sh) | VM（`/srv/app`） | secrets → 清舊 image → pull → migrate → rollout → worker → 清舊 image | 正式環境 |
| [`release.sh`](release.sh) | 本機 | Cloud Build 建置 HEAD，再登入 VM 執行 `deploy.sh`；`--deploy-only <tag>` 回滾 | 正式環境 |
| [`backup.sh`](backup.sh) | VM（systemd timer） | 每晚 `pg_dump` 上傳到只能寫入的 bucket | GCS |
| [`probe.sh`](probe.sh) | 本機 | 部署期間持續打網址，統計失敗數 | 唯讀 |
| [`cutover.sh`](cutover.sh) | 本機 | 正式切換，要加 `--confirm`：最後一次同步檔案 → 停 Zeabur 自動部署、暫停 API、排空、暫停 worker → 同步資料庫 → 驗證 → GCP 離開 standby。DNS 與轉址不在裡面；暫停 Zeabur 之後失敗就跑 `rollback.sh` | Zeabur、GCP |
| [`rollback.sh`](rollback.sh) | 本機 | 退回 Zeabur，要加 `--confirm`：GCP 回 standby → Zeabur 自動部署改回原分支 → 叫醒 API 與 worker（restart，不行再 redeploy）並等到 RUNNING；最後印出要人做的部分。**還沒有在真實的切換中跑過** | Zeabur、GCP |
| [`retire-zeabur-frontends.sh`](retire-zeabur-frontends.sh) | 本機 | DNS 切過來之後：舊前台換成轉址（碼照 `Caddyfile`：先 302，確定不退回後改 301 再跑一次），等轉址生效（新網址還是 Zeabur 回應就拒絕） | Zeabur |
| [`verify-admin-block.sh`](verify-admin-block.sh) | 本機 | 確認後台 API 只能從 Access 後面進去 | 唯讀 |
| [`fetch-minio-data.sh`](fetch-minio-data.sh) | 本機 | 最後封存：逐檔取回 MinIO 的 `/data` | 本機檔案 |
| [`final-archive.sh`](final-archive.sh) | 本機 | 最後封存：切換當晚的 dump、MinIO、volume 加密，金鑰進 Secret Manager，上傳 Archive bucket，下載解密驗證 | Secret Manager、GCS |
| [`cloudflare-access.py`](cloudflare-access.py) | 本機 | 建 email 一次性密碼登入與後台的 Access 應用 | Cloudflare |

設定範本在 [`../templates/`](../templates/)：`compose.example.yaml`、`cloudbuild.example.yaml`、`trust-proxy.ts`、`systemd/`、`zeabur-redirect/`。放到自己專案時，VM 上的檔案全部平放在同一個目錄（`release.sh` 預設是 `deploy/host/`）：`compose.yaml`、`deploy.sh`、`backup.sh`、`db-backup.service`、`db-backup.timer`。

`cutover.sh` 在動到 Zeabur 之前會先檢查所有設定都填了、`verify.sh` 的第三項（專案自己的檢查）也補上了、VM 讀到的是最新的 secret、HOLD 的憑證已經換成正式值、有 MinIO 時暫時金鑰已建立，任何一項沒做就不會開始。

dump、取回的檔案與比對結果放在工作目錄 `$WORK`（預設 `~/.zeabur-to-gcp-work`，權限 700），不放在專案目錄：裡面是正式環境的個資。

## 依階段的使用順序

| 階段 | 腳本 |
| --- | --- |
| Phase 0 準備 | `zeabur-api-check.py`（Zeabur 有沒有改版）→ `zeabur-inventory.py`（看清楚帳號下有什麼）→ `zeabur-discover.py <專案>`（盤點表與適用性檢查）→ 備份：`sync-db.sh --dump-only`、`fetch-minio-data.sh`、`sync-volume.sh --fetch-only` |
| Phase 1 基礎建設 | [`../infra/`](../infra/)：`bootstrap.sh` → `check-placeholders.py infra/gcp` → `tf.sh plan` → `tf.sh apply` |
| Phase 2 讓 VM 跑起來 | `init-secrets.sh` → `set-env.sh` → `cloudflare-access.py` → `setup-tunnel.sh` → `check-placeholders.py deploy infra/gcp` → `release.sh`（部署時開 `probe.sh`）→ 試跑 `backup.sh` → `verify-admin-block.sh` |
| Phase 3 資料搬移與演練 | `sync-db.sh` → `sync-env.sh` → `release.sh --deploy-only` → `sync-volume.sh`／`sync-assets.sh --create-key`、`sync-assets.sh`、`--delete-key` → `verify.sh`，完整跑兩輪：第二輪就是切換的演練。`cutover.sh` 會暫停正式環境，不能拿來演練 |
| Phase 4 正式切換 | 合併 Zeabur 部署的分支 → `sync-env.sh --live` → `release.sh` → `sync-assets.sh --create-key` → `cutover.sh --confirm` → 改 DNS 與外部後台 → 等 DNS 生效 → smoke test → `retire-zeabur-frontends.sh` → `sync-assets.sh --delete-key`；要退回時 `rollback.sh --confirm` |
| Phase 5 下線 | `fetch-minio-data.sh` → `final-archive.sh` → `zeabur-inventory.py` → 刪除服務 → 再跑一次 `zeabur-inventory.py` |

## 前置需求

- 本機：bash、python3、Node.js（`npx zeabur@0.24.0`）、gcloud、gpg、openssl、`pg_restore`（libpq）；後台用 Access 時還要 `cloudflared`。
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
