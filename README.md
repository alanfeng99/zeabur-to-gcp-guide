# Zeabur → GCP 遷移指南

把跑在 [Zeabur](https://zeabur.com) 上的 Web 應用（前台、API、背景 worker、Postgres、Redis、物件儲存）搬到 Google Cloud 的實戰指南，附可以直接改來用的腳本、設定範本與 Terraform。也可以直接交給 AI agent，由它一步一步帶你做。

整理自一次實際搬遷：Next.js 前台與後台、NestJS API、BullMQ worker，搬到一台 GCE VM 用 docker compose 執行。結果是每月約 US$40、正式切換約 5 分鐘、資料零差異、換版零失敗。內容已去掉專案細節，任何類似架構的專案都能照著走。

> 真正的風險不在資料，而在綁著 `*.zeabur.app` 的外部連結、兩套 worker 同時碰正式資料、加密金鑰，以及部署設定裡看不見的差異。這份指南大部分篇幅在處理這些。

![目標架構：公開網址直連 VM，後台頁面與後台 API 都在 Cloudflare Access 後面](docs/images/architecture.png)

## 交給 AI agent

這個 repo 附有給 agent 的操作手冊 [`AGENTS.md`](AGENTS.md)（Claude Code 透過 [`CLAUDE.md`](CLAUDE.md) 讀到同一份）。把 repo 抓到你的專案旁邊，在你的專案裡對 agent（Claude Code、Codex、Cursor 等）說：

```bash
git clone https://github.com/alanfeng99/zeabur-to-gcp-guide ../zeabur-to-gcp-guide
```

> 讀 `../zeabur-to-gcp-guide/AGENTS.md`，照它帶我把這個專案從 Zeabur 搬到 GCP。

agent 會：

- **先盤點**：用 [`zeabur-discover.py`](scripts/zeabur-discover.py) 讀出你的 Zeabur 專案（服務、image、volume、網域、環境變數的名稱，不讀值），並判斷這份指南適不適用：哪些照做、哪些要調整、哪些不在涵蓋範圍。
- **建一份 `MIGRATION.md` 追蹤進度**（範本：[`docs/MIGRATION.template.md`](docs/MIGRATION.template.md)），換 session 也能接著做。
- **每個會改變東西的步驟都先停下來問你**：建 GCP 專案、寫入 secret、換資料庫、部署、切換、改 DNS、刪除。
- **不要你把密碼或金鑰貼進對話**：需要時給你一行用隱藏輸入的指令，在你自己的終端機執行。

## 內容

| 位置 | 內容 |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | 給 AI agent 的操作手冊：開場要做的事、絕對規則、檔案放哪裡、每個階段的步驟與關卡、進度檔 |
| [`docs/guide.md`](docs/guide.md) | 完整指南：開工前的五個問題、架構選擇與費用、盤點、分階段流程與檢查清單、要準備的文件、不停機部署、切換當晚的 runbook、下線 Zeabur、28 個實際踩過的陷阱 |
| [`infra/`](infra/) | Terraform：VM、資料碟與每日快照、只走 IAP 的 SSH、固定 IP、Artifact Registry、只能寫入的備份 bucket、Cloud Build 服務帳號、Secret Manager、預算警示；VM 開機腳本 |
| [`scripts/`](scripts/) | 每個步驟用到的腳本：盤點與適用性檢查、資料庫搬移與逐表比對、環境變數與金鑰指紋、物件複製、部署與回滾、每晚備份、切換、轉址、最後的加密封存、Cloudflare Access。[一覽與使用順序](scripts/README.md) |
| [`templates/`](templates/) | VM 上的 `compose.yaml`（Traefik 零停機設定、路由）、Cloud Build、systemd 備份 timer、舊網址轉址服務、真實 IP 的 `trust proxy` 函式 |
| [`tests/`](tests/) | 這個 repo 自己的檢查：`tests/run.sh`（見「參與」） |

## 自己來

1. **先讀 [開工前的五個問題](docs/guide.md#開工前先回答的五個問題)**，任何一題答不出來先別動工。
2. **盤點**：`python3 -I scripts/zeabur-discover.py <專案>`，看適用性結論。
3. **選架構**：小流量選單機（約 US$40／月）；要 SLA 就選全託管（約 US$150–230／月）。見 [選架構](docs/guide.md#選架構)。
4. **把 [各階段檢查清單](docs/guide.md#各階段檢查清單) 複製成 issue**，逐項勾。
5. **複製 `infra/`、`scripts/`、`templates/` 到自己的專案**（建議的位置見 [`AGENTS.md`](AGENTS.md#檔案放在使用者的專案裡)），把 `<...>` 換成自己的值。
6. **搬移腳本完整跑兩輪**（`sync-db.sh` → `sync-env.sh` 加 `release.sh --deploy-only` → `sync-volume.sh`／`sync-assets.sh` → `verify.sh`）再正式切換；第二輪就是演練，順便量出每一步要多久。`cutover.sh` 會暫停正式環境，只在切換當晚跑。

![遷移路線圖：每個階段過關才往下走；正式切換只佔一個晚上](docs/images/roadmap.png)

## 幾個最容易出事的地方

完整的 28 條在 [陷阱一覽](docs/guide.md#陷阱一覽)，這幾條最常見、代價也最大：

- **Zeabur 的自動部署關不掉**：暫停的服務會在下次合併時被重新部署，變成兩套 worker 同時對客戶發訊息。用 GraphQL 把 Git trigger 指到不存在的分支（[`zeabur-git-trigger.py`](scripts/zeabur-git-trigger.py)）。
- **Next.js 的 `NEXT_PUBLIC_*` 在建置時寫死**：只改執行期的環境變數沒有效果；舊網址的回訪者還會卡在快取裡的舊 JS，所以舊前台要換成 302 轉址。
- **Cloudflare Access 只擋網域**：後台頁面擋住了，後台呼叫的 API 若在另一個公開網域照樣能打；而 Express 預設不分大小寫，`/API/Admin` 也會路由到後台。
- **系統碟被舊 image 塞滿**：預設的 `docker image prune` 只刪沒有 tag 的，每版約 4 GB 會一直累積。
- **驗證本身要有陽性對照**：兩個空檔案也會「一致」，空的金鑰兩邊指紋也相同。

## 適用範圍與現況

- **涵蓋**：由原始碼建置的 Node／Next.js 類 app、Postgres、Redis、MinIO（或其他 S3 相容儲存），搬到單台 VM。其他組合（MySQL／MariaDB、MongoDB、WordPress、Cloud Run、Cloud SQL）`zeabur-discover.py` 會標出來，要自己調整。
- **驗證程度**：整套流程在一次實際搬遷中跑過；這裡是去識別化之後的版本，唯讀的腳本（盤點、探測、封鎖驗證）都實際跑過。[`tests/run.sh`](tests/run.sh) 檢查語法、shellcheck、Terraform、compose、環境變數的分類，把檔案複製成模擬的使用者專案跑佔位值檢查與設定錯誤時的停止點，並在 Debian、Alpine、Postgres 容器裡實際跑 dump、打包與解開的指令。會改變東西的腳本在去識別化後還沒有對真實服務完整跑過一輪：第一次使用時請在 Phase 3 照常演練兩輪，有問題請回報。

## 前置需求

- Zeabur CLI（`npx zeabur@0.24.0`，固定版本）與登入
- Google Cloud 帳單帳號、gcloud CLI、Terraform ≥ 1.6
- 本機：bash、python3、Node.js、gpg、openssl、`pg_restore`
- （選用）Cloudflare 帳號：後台走 tunnel＋Access

## 參與

歡迎開 issue 或 PR：補充其他架構的做法、修正過時的指令、分享新的陷阱。請保持內容與特定專案無關：範例一律用 `example.com` 與 `<...>` 佔位，不要放任何真實的 ID、網域或金鑰。

發 PR 前在本機跑一次，全部通過才發（要 Docker，不會連到 Zeabur 或 GCP）：

```bash
tests/run.sh                # 全部，約一分鐘
tests/run.sh static unit    # 只跑其中幾段：static、unit、layout、container、docs
```

改了腳本裡被測的那幾行（容器內的 dump 與打包、VM 上的解開、檢查的停止點），測試會直接取出新的寫法來跑；改了訊息文字，`tests/run.sh` 裡對應的預期也要一起改。`main` 受保護，改動一律走 PR。

## 授權

[MIT](LICENSE)

---

## English summary

A field guide and toolkit for moving a web app from Zeabur to Google Cloud: frontends, an API, a background worker, Postgres, Redis and S3-compatible object storage, onto a single GCE VM running docker compose (about US$40/month, a ~5-minute cutover, zero data drift, zero-failure deploys).

**Hand it to an AI agent.** [`AGENTS.md`](AGENTS.md) is a playbook for coding agents (Claude Code reads it through `CLAUDE.md`). Clone this repo next to your project and ask your agent to read `AGENTS.md` and guide you through the migration. It inventories your Zeabur project with [`zeabur-discover.py`](scripts/zeabur-discover.py) (metadata and variable names only, never values), checks whether your stack fits, tracks progress in a `MIGRATION.md`, stops for your confirmation before anything that changes infrastructure or production, and never asks you to paste secrets into the chat.

- [`docs/guide.md`](docs/guide.md): the full guide (in Traditional Chinese), including 28 pitfalls hit in practice.
- [`infra/`](infra/): Terraform for the VM, data disk with daily snapshots, IAP-only SSH, a fixed IP, Artifact Registry, a write-only backup bucket, Secret Manager and a budget alert.
- [`scripts/`](scripts/) and [`templates/`](templates/): every script and config used in the migration, sanitized.

Replace every `<...>` with your own values. Scripts that change production say so at the top; rehearse on staging first.

Contributing: run [`tests/run.sh`](tests/run.sh) before opening a PR (needs Docker; it never touches Zeabur or GCP). `main` only accepts pull requests.
