# 基礎建設（Terraform）

[`modules/compose-host`](modules/compose-host/) 建出一台跑 docker compose 的 VM，以及 Zeabur 原本替你處理、搬到 GCP 要自己補上的東西：

| 資源 | 設定 |
| --- | --- |
| VM | Debian 12、e2-medium、Shielded VM、OS Login；開機腳本會掛資料碟、建 swap、裝 Docker 與 Ops Agent、設定 `mirror.gcr.io`（[`startup.sh.tftpl`](modules/compose-host/startup.sh.tftpl)） |
| 資料碟 | 獨立的 `/srv`，`prevent_destroy`，每日快照（保留 14 天） |
| 網路 | 自己的 VPC；SSH 只開給 IAP 的網段；`public_https` 開啟時才開 80／443 |
| 固定 IP | 進出站同一個位址：DNS 指向它，合作方的 IP 白名單也用它 |
| Artifact Registry | 每個 image 保留最新 10 版，其餘 30 天後刪除 |
| Cloud Build | 獨立的服務帳號：只能讀上傳的原始碼、推 image，碰不到備份與 secret |
| Bucket | `<project>-backups`（VM 只能建立物件，不能讀、改、刪；90 天自動過期）、`<project>-assets`（app 的檔案）、`<project>-build`（建置用，7 天過期） |
| 服務帳號 | VM、Cloud Build 各一個；另一個只對 assets bucket 有權限，app 用 S3 API 存取 GCS 的 HMAC 金鑰屬於它（金鑰由 [`init-secrets.sh`](../scripts/init-secrets.sh) 建，不進 state） |
| Secret Manager | 只建容器，值另外寫入，所以不會進 Terraform 的 state；VM 能讀 |
| 預算警示 | 50%、90%、100%，以及預測會超過 100% 時 |

## 用法

```bash
# 1. 一次性：建 project、綁帳單、建放 Terraform state 的 bucket（開版本控制）
./bootstrap.sh <project-id> <billing-account-id> asia-east1

# 2. 填設定
cp envs/prod/terraform.tfvars.example envs/prod/terraform.tfvars   # 填 project、帳單、名稱、預算
#    envs/prod/main.tf 的 backend bucket 也要把 <project-id> 換掉（backend 不能讀變數）

# 3. 以 gcloud 的使用者帳號執行（不讀 ADC）
./tf.sh init
./tf.sh plan
./tf.sh apply      # 會建立付費資源：先看過 plan

# 4. 之後要用的值
./tf.sh output
```

`./tf.sh output` 的 `host_name`、`host_zone`、`egress_ip`、`image_repository`、`assets_bucket`、`assets_service_account`、`build_service_account`、`ssh_command` 會用在 [`../scripts/zeabur-lib.sh`](../scripts/zeabur-lib.sh)、[`release.sh`](../scripts/release.sh) 與 [`cloudbuild.example.yaml`](../templates/cloudbuild.example.yaml)。

## 注意

- **`public_https`**：`true`（預設的 `envs/prod`）是公開網址直連 VM、Traefik 自己簽 Let's Encrypt；`false` 是 VM 沒有對外 IP，所有流量都經 Cloudflare tunnel，出站走 Cloud NAT。兩種模式之間切換的步驟寫在 [`variables.tf`](modules/compose-host/variables.tf) 的說明裡。
- **刪不掉的東西**：資料碟有 `prevent_destroy`、VM 有 `deletion_protection`。真的要刪，先改設定再 apply。
- **Secret 的值**不經過 Terraform：用 `gcloud secrets versions add <name> --data-file=-` 從隱藏輸入或檔案寫入。
- **gcloud 的預設值**：`tf.sh` 與所有腳本都明確帶 project 與 zone；看 GCP 後台時先確認左上角的 project。
