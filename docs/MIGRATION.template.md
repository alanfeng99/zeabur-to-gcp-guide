# 遷移進度：<專案名稱>

> 由 agent 維護（規則見 zeabur-to-gcp-guide 的 AGENTS.md）。每個 session 開始時先讀，結束前更新。
> 時間一律 UTC 並註明日期。不寫任何 secret 的值：只寫名稱與指紋的前 12 碼。

## 摘要

| 項目 | 現況 |
| --- | --- |
| 目前階段 | Phase 0 準備 |
| 下一步 | |
| 等使用者決定 | |
| 預定切換時間（UTC） | |
| Rollback 期限 | |

## 開工前的五個問題

1. 為什麼要搬：
2. 綁著 `*.zeabur.app` 的外部系統：（見下方「外部整合」）
3. 資料量與版本：資料庫 ＿＿ MB、Postgres ＿＿、物件 ＿＿ 個／＿＿ MB
4. 合作方的 IP 白名單：
5. 是不是適合當第一個搬的專案：

## 決定

| 日期（UTC） | 決定 | 理由 | 誰決定 |
| --- | --- | --- | --- |
| | 架構： | | |
| | 新網域： | | |
| | 後台用 Cloudflare Access： | | |
| | 每月預算： | | |

## 盤點

`zeabur-discover.py` 的輸出：`~/.zeabur-to-gcp-work/inventory.md`（工作目錄，不進版控）。適用性結論：

**要調整的項目與處理方式**

- 

### 外部整合

| 網址或整合 | 方向（進站／出站） | 切換時要改哪裡 | 負責人 | 完成 |
| --- | --- | --- | --- | --- |
| | | | | [ ] |

### 排程

| 排程 | 頻率 | 在哪個服務 | 切換時注意 |
| --- | --- | --- | --- |
| | | | |

## 設定（不含 secret 的值）

| 設定 | 值 | 來源 |
| --- | --- | --- |
| Zeabur 部署的分支 | | `zeabur-discover.py` |
| 遷移分支 | | 自己開的 |
| 目前部署的 tag | | `release.sh`（commit 前 12 碼） |
| GCP project | | |
| Region／zone | | |
| VM | | `infra/gcp/tf.sh output host_name` |
| 固定 IP | | `infra/gcp/tf.sh output egress_ip` |
| Image repository | | `infra/gcp/tf.sh output image_repository` |
| Secret Manager | app-env、encryption-key、cloudflared-tunnel-token | Terraform |
| 加密金鑰指紋（前 12 碼） | | `sync-env.sh` |
| 備份 bucket | | `infra/gcp/tf.sh output backups_bucket` |

## 階段與關卡

### Phase 0　準備

- [ ] 五個問題都有答案
- [ ] 盤點完成，適用性結論已和使用者確認
- [ ] 環境變數分類已逐一確認
- [ ] 外部整合都有負責人
- [ ] 遷移分支已建立，檔案已複製、`zeabur-lib.sh` 的 Zeabur 設定已填
- [ ] 完整備份（存放位置：）
- [ ] Zero Trust 已開通（若用 Access）

關卡：

### Phase 1　基礎建設

- [ ] bootstrap
- [ ] `./tf.sh apply`（plan 摘要：）
- [ ] 輸出值已填進腳本與上方「設定」

關卡：

### Phase 2　讓 VM 跑起來

- [ ] 每個 app 都有 Dockerfile，本機建置過
- [ ] 名稱已對齊：`build-app-env.py` 的分類、加密金鑰的變數名稱、檔案存放的變數名稱、服務名稱、健康檢查
- [ ] compose 已依 app 調整
- [ ] `init-secrets.sh`、`set-env.sh` 已補上 staging 的值
- [ ] 連續部署 ＿ 輪，探測 ＿ 次、失敗 ＿
- [ ] 每晚備份成功、VM 刪不掉備份
- [ ] worker 優雅關機
- [ ] `verify-admin-block.sh` 全部通過

關卡：

### Phase 3　資料搬移與演練

| 輪次 | 合併 Zeabur 分支（tag） | sync-db（表數一致） | sync-env＋重新部署 | volume／assets（檔案數） | verify | 總耗時 |
| --- | --- | --- | --- | --- | --- | --- |
| 第一輪 | | | | | | |
| 第二輪 | | | | | | |

- [ ] 每個第三方服務呼叫成功
- [ ] 會對外發訊息的憑證已列進 HOLD，standby 期間沒有正式值
- [ ] VM 的 `/srv` 空間足夠，舊的 `postgres-replaced-*` 經同意後清掉
- [ ] 要改的 DNS 記錄 TTL 已降到 300 秒

關卡：

### Phase 4　正式切換

- [ ] 切換前：合併 Zeabur 分支、`sync-env.sh --live`、`release.sh`（tag：）、`sync-assets.sh --create-key`（有 MinIO 時）
- 開始時間（UTC）：
- 各步驟耗時：
- DNS 與外部後台：
- Smoke test：
- [ ] 舊前台已換成轉址（`retire-zeabur-frontends.sh`）
- 結果：
- [ ] 暫時 HMAC 金鑰已刪除（有 MinIO 時）
- [ ] 遷移分支已合併回 Zeabur 原本部署的分支

### Phase 5　觀察與下線

- [ ] 舊網址轉址正常（深層連結、帶參數）
- [ ] 備份每天產生，實際還原過一次
- [ ] 轉址 302 → 301（改 `Caddyfile`，再跑一次 `retire-zeabur-frontends.sh`）
- [ ] 加密金鑰已存進密碼管理器，指紋一致（前 12 碼：）
- [ ] 最後封存（位置與金鑰名稱：），下載解密驗證過
- [ ] 工作目錄 `$WORK` 已刪除
- [ ] Zeabur 服務已刪除，2 小時後確認
- [ ] 空專案已刪除
- [ ] GitHub App 已移除這個 repo 的存取權

## 紀錄

| 時間（UTC） | 做了什麼 | 結果 |
| --- | --- | --- |
| | | |
