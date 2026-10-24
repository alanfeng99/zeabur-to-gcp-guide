# Zeabur → GCP 遷移指南

把跑在 [Zeabur](https://zeabur.com) 上的 Web 應用（前台、API、背景 worker、Postgres、Redis、物件儲存）搬到 Google Cloud 的實戰指南，附可以直接改來用的腳本與設定範本。

整理自一次實際搬遷：Next.js 前台與後台、NestJS API、BullMQ worker，搬到一台 GCE VM 用 docker compose 執行。結果是每月約 US$40、正式切換約 5 分鐘、資料零差異、換版零失敗。內容已去掉專案細節，任何類似架構的專案都能照著走。

> 真正的風險不在資料，而在綁著 `*.zeabur.app` 的外部連結、兩套 worker 同時碰正式資料、加密金鑰，以及部署設定裡看不見的差異。這份指南大部分篇幅在處理這些。

![目標架構：公開網址直連 VM，後台頁面與後台 API 都在 Cloudflare Access 後面](docs/images/architecture.png)

## 內容

| 位置 | 內容 |
| --- | --- |
| [`docs/guide.md`](docs/guide.md) | 完整指南：開工前的五個問題、架構選擇與費用、盤點、分階段流程與檢查清單、要準備的文件、不停機部署、切換當晚的 runbook、下線 Zeabur、26 個實際踩過的陷阱 |
| [`scripts/`](scripts/) | 每個步驟用到的腳本：分片取回檔案、資料庫搬移與逐表比對、環境變數與金鑰指紋、物件複製、部署與回滾、每晚備份、切換、轉址、最後的加密封存、Cloudflare Access。[一覽與使用順序](scripts/README.md) |
| [`templates/`](templates/) | VM 上的 `compose.yaml`（Traefik 零停機設定、路由）、Cloud Build、systemd 備份 timer、舊網址轉址服務、真實 IP 的 `trust proxy` 函式 |

## 怎麼用

1. **先讀 [開工前的五個問題](docs/guide.md#開工前先回答的五個問題)**，任何一題答不出來先別動工。
2. **選架構**：小流量選單機（約 US$40／月）；要 SLA 就選全託管（約 US$150–230／月）。見 [選架構](docs/guide.md#選架構)。
3. **把 [各階段檢查清單](docs/guide.md#各階段檢查清單) 複製成 issue**，逐項勾。
4. **複製 `scripts/` 與 `templates/` 到自己的專案**，把 `scripts/zeabur-lib.sh` 與各範本裡的 `<...>` 換成自己的值。
5. **搬移腳本完整跑兩輪**（`sync-env.sh` → `sync-db.sh` → `sync-assets.sh` → `verify.sh`）再正式切換；第二輪就是演練，順便量出每一步要多久。`cutover.sh` 會暫停正式環境，只在切換當晚跑。

![遷移路線圖：每個階段過關才往下走；正式切換只佔一個晚上](docs/images/roadmap.png)

## 幾個最容易出事的地方

完整的 26 條在 [陷阱一覽](docs/guide.md#陷阱一覽)，這幾條最常見、代價也最大：

- **Zeabur 的自動部署關不掉**：暫停的服務會在下次合併時被重新部署，變成兩套 worker 同時對客戶發訊息。用 GraphQL 把 Git trigger 指到不存在的分支（[`zeabur-git-trigger.py`](scripts/zeabur-git-trigger.py)）。
- **Next.js 的 `NEXT_PUBLIC_*` 在建置時寫死**：只改執行期的環境變數沒有效果；舊網址的回訪者還會卡在快取裡的舊 JS，所以舊前台要換成 302 轉址。
- **Cloudflare Access 只擋網域**：後台頁面擋住了，後台呼叫的 API 若在另一個公開網域照樣能打；而 Express 預設不分大小寫，`/API/Admin` 也會路由到後台。
- **系統碟被舊 image 塞滿**：預設的 `docker image prune` 只刪沒有 tag 的，每版約 4 GB 會一直累積。
- **驗證本身要有陽性對照**：兩個空檔案也會「一致」，空的金鑰兩邊指紋也相同。

## 前置需求

- Zeabur CLI（`npx zeabur@0.24.0`，固定版本）與登入
- Google Cloud 專案、gcloud CLI、建議用 Terraform 建基礎設施
- 本機：bash、python3、Node.js、gpg、openssl、`pg_restore`
- （選用）Cloudflare 帳號：後台走 tunnel＋Access

## 參與

歡迎開 issue 或 PR：補充其他架構（例如 Cloud Run、Cloud SQL）的做法、修正過時的指令、分享新的陷阱。請保持內容與特定專案無關：範例一律用 `example.com` 與 `<...>` 佔位，不要放任何真實的 ID、網域或金鑰。

## 授權

[MIT](LICENSE)

---

## English summary

A field guide for moving a web app from Zeabur to Google Cloud: frontends, an API, a background worker, Postgres, Redis and S3-compatible object storage, onto a single GCE VM running docker compose (about US$40/month, a ~5-minute cutover, zero data drift, zero-failure deploys).

- [`docs/guide.md`](docs/guide.md): the full guide (in Traditional Chinese): go/no-go questions, architecture options and cost, inventory, phased checklists, zero-downtime deploys with Traefik and docker-rollout, the cutover runbook, decommissioning Zeabur, and 26 pitfalls hit in practice.
- [`scripts/`](scripts/): every script used in the migration, sanitized. Chunked file transfer out of Zeabur containers, database migration with per-table row-count checks, env vars to Secret Manager with key fingerprint checks, MinIO → GCS copy, release/deploy/rollback, nightly backups, the cutover script, redirects for the old `*.zeabur.app` URLs, an encrypted final archive, and Cloudflare Access setup.
- [`templates/`](templates/): `compose.yaml`, Cloud Build, systemd backup timer, the redirect service and an Express `trust proxy` function for mixed proxy depths.

Replace every `<...>` with your own values. Scripts that change production say so at the top; run them against staging first.
