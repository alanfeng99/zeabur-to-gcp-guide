# AGENTS.md：給 AI agent 的操作手冊

你拿到這個 repo，是要**帶你的使用者把他的專案從 Zeabur 搬到 GCP**。這份檔案告訴你怎麼做。
完整的道理與背景在 [`docs/guide.md`](docs/guide.md)；腳本在 [`scripts/`](scripts/)（一覽見
[`scripts/README.md`](scripts/README.md)），設定範本在 [`templates/`](templates/)，基礎建設在 [`infra/`](infra/)。

你的工作：解釋每一步、先跑唯讀的檢查、準備設定與指令、在使用者明確同意後執行會改變東西的步驟、
維護進度檔。你不替使用者做決定：架構、網域、切換時間、刪除什麼，都由使用者決定。

用使用者的語言溝通。時間一律記成 UTC 並註明日期（台灣凌晨的切換在 UTC 是前一天）。

下面用 `<guide>` 代表這個 repo 在使用者電腦上的路徑（通常是 clone 在使用者專案旁邊的
`../zeabur-to-gcp-guide`），指令都從**使用者專案的根目錄**執行。

## 每個 session 開始時

1. **找進度檔**：使用者專案根目錄的 `MIGRATION.md`。
   - 有：讀它，告訴使用者目前在哪個階段、下一步是什麼、有哪些事等他決定，確認狀態沒變再繼續。
   - 沒有：從 Phase 0 開始，用 [`docs/MIGRATION.template.md`](docs/MIGRATION.template.md) 建一份。
2. **確認工具與登入**（唯讀）：
   - `npx zeabur@0.24.0 auth status`：401 就請使用者在**他自己的終端機**跑 `npx zeabur@0.24.0 auth login`（網站登入不會更新 CLI 的 token）。
   - `gcloud auth list`、`gcloud config list`：記下預設的 project 與 zone，但**所有指令都明確帶 `--project` 與 `--zone`**，不依賴預設值。
   - `terraform version`、`bash --version`、`python3 --version`、`gpg --version`、`pg_restore --version`、`openssl version`；
     用 Cloudflare 時還有 `cloudflared --version`；`gh` 可有可無。
3. **確認目前的 git 分支**：遷移的工作都在遷移分支上（見下面「分支」），不在 Zeabur 部署的分支上。
4. **先讀 [`docs/guide.md`](docs/guide.md) 的「陷阱一覽」**，裡面每一條都是實際發生過的。

## 絕對規則

**這些動作要先停下來，等使用者在對話裡明確同意才做。** 先說清楚要做什麼、會影響什麼、怎麼退回。
一次同意只算那一個動作，不能延伸到下一個。

| 動作 | 為什麼要停 |
| --- | --- |
| Phase 0 的備份（`sync-db.sh --dump-only`、`fetch-minio-data.sh`、`sync-volume.sh --fetch-only`） | 在正式環境的容器裡 dump、打包，會吃 CPU、IO 與容器的 `/tmp` |
| `bootstrap.sh`、`infra/gcp/tf.sh apply` | 建立 GCP 專案、綁帳單、開始計費 |
| `init-secrets.sh`、`set-env.sh`（使用者自己在終端機跑） | 產生密碼與金鑰、寫進 Secret Manager |
| `cloudflare-access.py`、`setup-tunnel.sh` | 在使用者的 Cloudflare 帳號建立 Access 應用、tunnel 與 DNS 記錄 |
| `git commit`、`git push`、合併分支 | 使用者的歷史；推到 Zeabur 部署的分支會觸發正式環境重新建置 |
| `release.sh` | 部署到 VM。Phase 2（沒有真實資料與使用者）可以請使用者一次同意「這個階段需要時就部署」；Phase 3 起每次都要問 |
| `sync-env.sh`（加不加 `--live` 都是） | 把正式環境的設定與加密金鑰寫進 Secret Manager |
| `sync-db.sh`（不加 `--dump-only`） | 換掉 VM 上的資料庫（舊的資料目錄改名保留） |
| `sync-volume.sh`（不加 `--fetch-only`） | 清空並換掉 VM 上的目錄 |
| `sync-assets.sh --create-key`、`sync-assets.sh`、`sync-assets.sh --delete-key` | 建立／刪除存取 GCS 的金鑰；寫入 GCS |
| `cutover.sh --confirm` | 暫停 Zeabur 的正式服務；要在約好的時間、使用者在場時才跑 |
| `rollback.sh --confirm` | GCP 回 standby、叫醒 Zeabur |
| 任何 `zeabur service suspend`／`restart`／`redeploy`／`delete`、`project delete` | 正式環境停擺、重啟或資料消失 |
| 改 DNS、改外部後台（webhook、OAuth callback、金流） | 影響真實使用者 |
| `retire-zeabur-frontends.sh` | 舊網址從此只會轉址 |
| `final-archive.sh` 與之後的刪除 | 刪除不能復原 |
| 刪除任何檔案、資料目錄（包括 VM 上舊的 `postgres-replaced-*`）、bucket、secret、金鑰 | 不能復原 |

**Secret**
- 永遠不要請使用者把密碼、金鑰、token 貼進對話，也不要把它們印出來、寫進專案或 commit。
- **不要執行會把 secret 的值印到輸出的指令**：你看到的輸出就進了對話。包括：
  - `zeabur variable list`、`gcloud secrets versions access`、`gcloud storage hmac create`：一律導向到 `umask 077` 的檔案，而且不要讀那個檔案。
  - `docker compose config`（會把 `env_file` 與 `.env` 的值展開印出；只用 `--services`、`--images` 這類只印名稱的選項）、`docker inspect`。
  - 容器裡的 `env`、`printenv`、`cat /proc/*/environ`：`docker compose exec <服務> env`、`zeabur service exec … env` 都一樣。
  - `cat` 或打開 `app.env`、`.env`、`$WORK` 裡的任何備份。

  腳本已經照這個規則寫好，直接用腳本。除錯時只看變數**名稱**（例如 `… | cut -d= -f1`）或指紋（`shasum -a 256 | cut -c1-12`）。
- 需要使用者輸入時，給他一行在**他自己的終端機**執行的指令，用隱藏輸入：`read -rs VAR; export VAR`、
  `security add-generic-password -U -a "$USER" -s <name> -w`（macOS Keychain），或 `set-env.sh`。
- 進度檔可以寫 secret 的**名稱**與指紋的前 12 碼，不寫值。

**其他**
- **唯讀優先**：每個階段先跑唯讀的檢查，把結果給使用者看，再提要改的東西。
- **驗證要有陽性對照**：兩個空檔案也會「一致」。報告要誠實：失敗就說失敗，沒驗證就說沒驗證。
- **不要關 Zeabur 帳號、不要整個解除安裝 Zeabur 的 GitHub App**：帳號下常常還有別的正式網站。刪除一律用 ID，不用名稱。
- **不在涵蓋範圍的服務**（`zeabur-discover.py` 會標出來）：不要硬套腳本。說明差異，和使用者決定怎麼做（另外改寫、先不搬、只搬一部分）。
- **找根因再修**：腳本失敗時先讀設定、看日誌、確認實際狀態，提出一個修正；第一個修正沒用就回頭重新診斷，不要一直試。

## 檔案放在使用者的專案裡

這個 repo 是工具箱。Phase 0 盤點完、使用者決定要搬之後，把需要的檔案複製到使用者的專案
（先告訴使用者你要放哪些檔案），在那裡改設定：

```
<使用者的專案>/
  MIGRATION.md                      ← docs/MIGRATION.template.md
  infra/gcp/                        ← infra/（整個目錄：bootstrap.sh、tf.sh、modules/、envs/）
  deploy/release.sh                 ← scripts/release.sh
  deploy/cloudbuild.yaml            ← templates/cloudbuild.example.yaml
  deploy/host/                      ← VM 上的檔案，全部平放：
      compose.yaml                  ←   templates/compose.example.yaml
      deploy.sh、backup.sh          ←   scripts/
      db-backup.service、.timer     ←   templates/systemd/
  deploy/migrate/                   ← 其餘的 scripts/（zeabur-lib.sh、sync-*.sh、cutover.sh、*.py …）
  deploy/templates/zeabur-redirect/ ← templates/zeabur-redirect/
```

複製時保留執行權限（`cp -p`）。用不到的不要複製，`check-placeholders.py` 會檢查 `deploy/` 底下每個檔案：沒有 MinIO 就不要
`sync-assets.sh`、`fetch-minio-data.sh`、`copy-assets.js`；沒有 volume 就不要 `sync-volume.sh`；後台不用 Access 就不要
`cloudflare-access.py`、`setup-tunnel.sh`。在使用者的 `.gitignore` 加這幾行（不要整份照搬這個 repo 的 `.gitignore`：
那些規則沒有錨定路徑，會蓋到使用者自己的目錄）：

```
.terraform/
*.tfstate
*.tfstate.*
infra/gcp/envs/*/terraform.tfvars
deploy/host/app.env
deploy/host/.env
*.dump
```

**工作目錄 `$WORK`**（預設 `~/.zeabur-to-gcp-work`，用 `MIGRATION_WORK` 改）：dump、取回的檔案、
環境變數備份、暫時金鑰、比對結果都放這裡，**不在使用者的 repo 裡**，權限 700。裡面是正式環境的個資與 secret，
你不要讀裡面的備份檔，最後由 Phase 5 收尾刪除。

## 分支

Zeabur 從某個分支（`ZEABUR_GIT_BRANCH`，discover 會列出）自動部署。專案裡**多一個 Dockerfile，Zeabur 下次建置就會改用它**，
不再用 zbpack 自動判斷，所以遷移的改動不能進到那個分支：

- Phase 0 從 Zeabur 部署的分支開一個遷移分支（例如 `gcp-migration`），所有改動都 commit 在這裡：Dockerfile、
  程式的修改、`deploy/`、`infra/gcp/`、`MIGRATION.md`。`release.sh` 只部署 commit 過的內容（`git archive HEAD`），
  漏 commit 的 Dockerfile 不會被建置。
- 每一輪 Phase 3 之前、切換當天，把 Zeabur 部署的分支合併進遷移分支，讓 GCP 跑的和 Zeabur 是同一版程式、同一個 schema。
  遷移分支上不改 schema。
- 切換完成、Zeabur 的自動部署停掉之後，才把遷移分支合併回去（**停**）。

## 階段流程

每個階段做完，把結果與證據寫進 `MIGRATION.md`，確認關卡都過了，才和使用者一起進入下一階段。
各階段的完整清單在 [guide 的「各階段檢查清單」](docs/guide.md#各階段檢查清單)。

### Phase 0　準備（不影響正式環境）

1. 建 `MIGRATION.md`，和使用者逐題討論 [開工前的五個問題](docs/guide.md#開工前先回答的五個問題)，答案寫進去。
2. 盤點（直接從 `<guide>` 執行，還不用複製任何檔案）：
   ```bash
   python3 -I <guide>/scripts/zeabur-discover.py            # 列出專案，和使用者確認是哪一個
   mkdir -p ~/.zeabur-to-gcp-work && chmod 700 ~/.zeabur-to-gcp-work
   python3 -I <guide>/scripts/zeabur-discover.py <專案> > ~/.zeabur-to-gcp-work/inventory.md
   ```
   它只讀 metadata 與變數**名稱**，不讀值，所以 `inventory.md` 可以讀。把**適用性結論**與「要調整」的每一項
   講給使用者聽；有「不在涵蓋範圍」的項目就先停下來討論。重點寫進 `MIGRATION.md` 的「盤點」。
3. 和使用者逐一確認：
   - **環境變數分類**：每個變數歸到 COPY（照抄）、DROP（拿掉）、SET（換成 GCP 的值）、KEEP（沿用 GCP 這邊產生的）、
     HOLD（會對外發訊息的憑證：通訊軟體、寄信、簡訊、金流）。discover 的建議只是依名稱猜的起點，每一個都要確認，尤其是加密金鑰。
   - **外部整合**：每一個進站網址（webhook、callback、寄出去的連結、QR code）要在哪個後台改、誰負責。
   - **排程**：有哪些、在哪個服務。
4. 決定：架構（[選架構](docs/guide.md#選架構)）、每月預算、目標 Postgres 版本（和 Zeabur 同一個 major）、
   後台要不要 Cloudflare Access，以及**網域**：
   - GCP 用新的網域（最簡單，也是實跑過的路）：切換後 Zeabur 的舊網址轉址過去。
   - 沿用 Zeabur 上已綁的自有網域、切換當晚只改 DNS：Phase 2–3 用另一個測試網域，Traefik 要改用
     DNS-01 才能在切換前拿到正式網域的憑證（compose 範本 traefik 的註解）。這條路還沒有完整實跑過，要先講清楚。
5. 開遷移分支（見上面「分支」），複製檔案到使用者專案，把 discover 建議的設定填進 `deploy/migrate/zeabur-lib.sh`：
   服務 ID、`GITHUB_REPO_ID`、`ZEABUR_GIT_BRANCH`、`ENCRYPTION_KEY_VAR`、`ZEABUR_MINIO_ID`、`VOLUMES`、`FILES_CHECK`，
   以及舊網址 `OLD_WEB_URL`／`OLD_ADMIN_URL` 與第 4 步決定的新網址 `NEW_WEB_URL`／`NEW_API_URL`／`NEW_ADMIN_URL`。
6. 完整備份到使用者的電腦（**停**：在正式容器裡 dump 與打包；腳本會先檢查容器的 `/tmp` 夠不夠，失敗時清掉容器裡的暫存檔）：
   ```bash
   # 環境變數：每個服務一個檔案，不印到螢幕
   ( umask 077; mkdir -p ~/.zeabur-to-gcp-work/env-backup
     for id in <每個服務的 ID>; do
       npx zeabur@0.24.0 variable list --id "$id" --env-id <environment-id> -i=false --json \
         > ~/.zeabur-to-gcp-work/env-backup/"$id".json
     done )
   deploy/migrate/sync-db.sh --dump-only        # 資料庫 → $WORK/zeabur.dump
   deploy/migrate/fetch-minio-data.sh           # 有 MinIO 時
   deploy/migrate/sync-volume.sh --fetch-only   # app 服務有 volume 時
   ```
   只用 `ls -l` 確認檔案存在、大小合理，不要打開。
7. 若要用 Cloudflare Access：請帳號擁有者開通 Zero Trust（這一步只能在 dashboard 做）。

### Phase 1　基礎建設

1. 照 [`infra/README.md`](infra/README.md) 填 `infra/gcp/envs/prod/terraform.tfvars` 與 backend bucket。
2. `infra/gcp/bootstrap.sh <project-id> <billing-account-id> <region>`（**停**）→ `python3 -I deploy/migrate/check-placeholders.py infra/gcp` 要印出 `no placeholders left` →
   `infra/gcp/tf.sh init` → `infra/gcp/tf.sh plan`，把 plan 摘要給使用者看 → `infra/gcp/tf.sh apply`（**停**）。
3. `infra/gcp/tf.sh output` 的值填進 `zeabur-lib.sh` 的 GCP 區塊、`deploy/release.sh` 開頭、`deploy/cloudbuild.yaml`
   的 image 路徑，也記進進度檔的「設定」。

### Phase 2　讓 VM 跑起來（staging 設定、空資料庫、沒有真實使用者）

1. **Dockerfile**：Cloud Build 用每個 app 自己的 Dockerfile。Zeabur 常用 zbpack 自動建置、專案裡**沒有 Dockerfile**，
   沒有就要和使用者一起寫（在遷移分支上），並在本機 `docker build` 過。image 要符合 compose 範本開頭寫的條件，不符合就改 compose：
   - healthcheck 用 bash（alpine 要裝 bash，或改成 `node -e`）；API 在 4000 回 `/api/health` 且內容含 `"status":"ok"`；
     前台在 3000 回 `/favicon.ico`。
   - Next.js 的 `NEXT_PUBLIC_*` 是建置參數，寫進 `cloudbuild.yaml`；執行期的變數由 compose 的 `env_file` 給。
   - worker 用哪個 image、什麼指令；migrate 用什麼指令。
2. **對齊名稱**：腳本裡有些名稱是寫死的，要改成使用者專案的：
   - [ ] `build-app-env.py` 的 COPY／DROP／SET／KEEP／HOLD：照 Phase 0 確認過的分類填，SET 填新網域。
   - [ ] 加密金鑰的變數名稱：`zeabur-lib.sh` 的 `ENCRYPTION_KEY_VAR` 與 `deploy.sh` 的 `ENCRYPTION_KEY_VAR` 相同；沒有加密金鑰兩邊都留空。
   - [ ] 檔案存放的變數名稱：`init-secrets.sh`、`build-app-env.py`、`copy-assets.js` 寫的是 `S3_*`；app 用 `MINIO_*`、`AWS_*` 之類就全部改。
     `copy-assets.js` 的 minio 套件路徑也依 image 改（app 用 `@aws-sdk` 就改寫成那個套件）。
   - [ ] 服務名稱：`deploy.sh`（`for service in api admin web`）、`restore-on-host.sh`（停止與啟動的服務清單）要和 `compose.yaml` 一致。
   - [ ] 健康檢查：`verify.sh` 打的 `/api/health` 與它檢查的 `"status":"ok"`。
   - [ ] 檔案檢查：`zeabur-lib.sh` 的 `FILES_KEY_QUERY` 寫成列出資料庫參照的每個檔案 key 的 SQL（和使用者一起看 schema）；
     `FILES_CHECK='none'` 時留空。
3. 依 app 調整 `compose.yaml`：服務名稱與 port、每個 router 的網域、Postgres 與 Redis 的 image（和 Zeabur
   一樣；redis-stack 見範本的註解）、`VOLUMES` 對應的掛載。有 `VOLUMES` 時先在 VM 上建好目錄、擁有者設成容器裡寫檔的使用者，
   否則 Docker 會建成 root 的目錄、上傳失敗：
   ```bash
   bash -c 'source deploy/migrate/zeabur-lib.sh && zexec <service-id> stat -c %u:%g <容器內目錄>'   # 例如 1000:1000
   bash -c 'source deploy/migrate/zeabur-lib.sh && gssh "sudo install -d -o <uid> -g <gid> <VM 上的目錄>"'
   ```
4. 使用者在自己的終端機跑 `deploy/migrate/init-secrets.sh`（**停**）：寫入 `app-env` 與 `encryption-key` 的第一個版本。
   app 開機就檢查的變數（JWT secret、第三方金鑰等）只有這些還起不來：使用者再跑 `deploy/migrate/set-env.sh --random <KEY>…`
   （隨機值）或 `set-env.sh <KEY>…`（隱藏輸入，例如第三方的測試金鑰）（**停**）。HOLD 的變數這裡給測試值或不給。
5. 後台用 Access 時：填好 `cloudflare-access.py` 開頭的三個值，使用者把 API token 存進 Keychain，
   跑 `cloudflare-access.py`（**停**）→ 使用者跑 `cloudflared tunnel login` → `setup-tunnel.sh <名稱>`（**停**）。
   順序不能反：DNS 記錄一建立就要已經在 Access 後面。
6. 公開網域的 DNS A 記錄指向 `egress_ip`（**停**），**不要開 Cloudflare 的 proxy**（灰色雲）：真實 IP 的判斷假設公開網域直連 VM。
7. `python3 -I deploy/migrate/check-placeholders.py deploy infra/gcp` 要印出 `no placeholders left` → 和使用者確認後
   在遷移分支 commit（**停**）→ `deploy/release.sh`（**停**）。部署期間另開 `probe.sh` 打**公開**網址（後台在 Access 後面，
   會回 302）；**連續部署多輪，失敗數必須是 0**。每次部署的 tag（commit 的前 12 碼）記進進度檔。
8. 每晚備份實際跑一次（VM 上 `sudo systemctl start db-backup.service`），確認 bucket 裡有新物件，再從 VM 試刪剛產生的那一個（**停**：
   權限設錯時真的會刪掉，所以只拿這份測試備份試），必須失敗。
9. 後台：`deploy/migrate/verify-admin-block.sh <公開 API 網址> <後台網址> <egress_ip>` 全部通過才算數。
10. 真實 IP：公開網域與後台網域經過的 proxy 層數不同時，app 要用 [`templates/trust-proxy.ts`](templates/trust-proxy.ts)
    這類做法（要改使用者的程式，先說明）。

### Phase 3　資料搬移與演練（正式資料、worker 停著）

每一輪：

1. 把 Zeabur 部署的分支合併進遷移分支（**停**）；有新的 commit 就 `release.sh`（**停**）。
2. `sync-db.sh`（**停**）：VM 進 standby（worker 停住，之後的部署也不會啟動它），還原後跑 migrate，每張表筆數一致才算過。
   筆數因為多了新的表而對不上，代表 GCP 跑的和 Zeabur 不是同一版。每輪都會留下一份舊的資料目錄：看
   `bash -c 'source deploy/migrate/zeabur-lib.sh && gssh "df -h /srv"'`，舊的 `/srv/data/postgres-replaced-*` 經使用者同意後刪除（**停**），只留最近一份。
3. `sync-env.sh`（**停**；不加 `--live`，HOLD 的憑證不放正式值）：環境變數換成正式值、加密金鑰比對指紋 →
   `release.sh --deploy-only <目前的 tag>`（**停**），VM 才會讀到新的 secret。
4. app 服務有 volume：`sync-volume.sh`（**停**）。有 MinIO：`sync-assets.sh --create-key` → `sync-assets.sh` →
   `sync-assets.sh --delete-key`（都**停**；金鑰只存在 `$WORK/dest-hmac.json`，不顯示）。
5. 和使用者一起補上 `verify.sh` 的第三項（專案自己的檢查，例如解開所有加密欄位），然後跑 `verify.sh`。
6. 每個第三方服務實際打一次最小的呼叫。

以上完整跑**兩輪**，第二輪就是演練，記下每一步的耗時。`cutover.sh` 會暫停正式環境，**不能拿來演練**。
切換前至少一天：要改的 DNS 記錄 TTL 降到 300 秒；`check-placeholders.py deploy infra/gcp` 再跑一次。

### Phase 4　正式切換

1. 和使用者約時間（避開排程），公告維護時段，定好 rollback 期限與誰有權決定退回。
2. 切換前一小時內（**每一項都停**）：
   - 把 Zeabur 部署的分支合併進遷移分支 → `sync-env.sh --live`（HOLD 換成正式憑證）→ `release.sh`。
     `cutover.sh` 會檢查 VM 讀的是最新的 secret、HOLD 已經是正式值。
   - 有 MinIO：`sync-assets.sh --create-key`。
3. 使用者在場、明確說開始後：`cutover.sh --confirm`（**停**）。每一步的結果即時告訴使用者。
   **步驟 1 之後失敗**（Zeabur 已暫停、GCP 還在 standby）：不要重跑，立刻問使用者要不要 `rollback.sh --confirm`
   讓 Zeabur 恢復服務，查出原因後另約時間。
4. 改 DNS 與外部後台（**停**；照盤點表逐項打勾）→ 用 `dig` 確認新網域已解析到 `egress_ip`、`curl -I` 確認憑證與回應 →
   smoke test：登入、送表單、上傳、背景任務、匯出。
5. `retire-zeabur-frontends.sh`（**停**；它會再檢查一次 DNS，沒切過來就不動）。有 MinIO：`sync-assets.sh --delete-key`（**停**）。
6. 期限內有問題：`rollback.sh --confirm`（**停**），再照它印出的步驟改回 DNS 與外部後台。`rollback.sh` 還沒有在真實的切換中跑過，
   切換前先和使用者一起讀一遍。
7. 確定不退回後，把遷移分支合併回 Zeabur 部署的分支（**停**）：這時 Zeabur 的自動部署已經停了。

### Phase 5　觀察與下線（兩到四週）

1. 監控、確認備份每天產生並實際還原一次。確定不會 rollback 後轉址改 301：`deploy/templates/zeabur-redirect/Caddyfile`
   的 `302` 改成 `301` → commit（**停**）→ 再跑一次 `retire-zeabur-frontends.sh`（**停**）。
2. **加密金鑰的離線備份**：Secret Manager 的 secret 一被刪，所有版本都不見，加密欄位與每一份備份都解不開。請使用者在自己的終端機
   把金鑰存進密碼管理器（例如 `gcloud secrets versions access latest --secret encryption-key --project <p> | pbcopy`，貼上後清掉剪貼簿），
   再比對指紋：你跑 `gcloud secrets versions access latest --secret encryption-key --project <p> | tr -d '\n' | shasum -a 256 | cut -c1-12`，
   使用者從密碼管理器複製後跑 `pbpaste | tr -d '\n' | shasum -a 256 | cut -c1-12`，兩邊一致才算數。
3. 最後封存：有 MinIO 時先 `fetch-minio-data.sh` → `final-archive.sh`（**停**）。它封存 `$WORK` 裡切換當晚的
   `zeabur.dump`、MinIO 與 volume，下載解密驗證過才算完成。上一項做完之後才刪除 `$WORK`（**停**）。
4. 刪除前：`python3 -I deploy/migrate/zeabur-inventory.py` 看清楚帳號下所有東西；確認沒有人還在用舊網址。
5. 刪除服務（**每一個都要停**）；2 小時後再跑一次 `zeabur-inventory.py` 確認；再刪空的專案。
6. 請使用者在 GitHub 的 Zeabur App 只移除這個 repo 的存取權。

## 進度檔

格式見 [`docs/MIGRATION.template.md`](docs/MIGRATION.template.md)。每完成一個步驟就更新：狀態、證據（指令輸出的重點，
例如「37 張表一致」「探測 628 次、失敗 0」）、時間（UTC）、部署的 tag。session 結束前一定要更新「下一步」與「等使用者決定」。

## 腳本有問題時

改使用者專案裡的那一份，並告訴使用者可以回報到這個 repo（開 issue 或 PR）。回報時不要附上任何真實的 ID、網域或金鑰。

## 改這個 repo 本身

使用者要你修改這個 repo（而不是帶使用者遷移）時：改完跑 `tests/run.sh`，全部通過才發 PR；`main` 受保護，只能走 PR。
範例只用 `example.com` 與 `<...>`，`tests/run.sh docs` 會擋公開 IP、24 碼 ID 與 email，專案名稱與網域要自己再 grep 一次。
