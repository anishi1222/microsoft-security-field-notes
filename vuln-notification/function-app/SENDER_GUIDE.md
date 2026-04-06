# Sender Guide (Function Notify API)

このガイドは、Function API に JSON を送信するクライアント実装者向けです。

## 1. 送信先 API

- Method: POST
- Path: /api/notify

URL はデプロイ後に取得した Function App 名で組み立てます。

```powershell
$deploymentName = "vuln-notify-infra"
$funcUrl = az deployment group show -g vuln-notify-rg -n $deploymentName --query "properties.outputs.functionAppUrl.value" -o tsv
$notifyUrl = "$funcUrl/api/notify"
$notifyUrl
```

## 2. 認証ヘッダー

必須ヘッダー:

- x-api-key: Key Vault の API-KEY
- Authorization: Bearer <user token or access_as_user token>
- Content-Type: application/json

### 2-1. API Key 取得例

```powershell
$kvName = az deployment group show -g vuln-notify-rg -n "vuln-notify-infra" --query "properties.outputs.keyVaultName.value" -o tsv
$apiKey = az keyvault secret show --vault-name $kvName --name API-KEY --query value -o tsv
```

### 2-2. Bearer token 取得例

```powershell
$token = az account get-access-token --scope "api://<API_APP_ID>/access_as_user" --query accessToken -o tsv
```

## 3. JSON スキーマ

### 3-1. 必須項目

- upn または upns のどちらか
  - upn: string
  - upns: string array または comma-separated string

注意:

- chat_id を省略する場合は、upns が 2 件以上必要
- UPN は重複除去され、小文字化されて処理される

### 3-2. 通知本文（任意）

- title: string
- message: string
- facts: object
  - 任意の key/value を Adaptive Card の FactSet に追加

### 3-3. チャット指定（任意）

- chat_id: string
  - 指定時はそのチャットに投稿
  - 未指定時は upns から group chat を作成

### 3-4. Planner（任意）

planner.enabled=true の場合に有効。

- planner.enabled: bool
- planner.plan_id: string (必須)
- planner.bucket_id: string (必須)
- planner.title: string (任意)
- planner.due_datetime: string (ISO8601, 任意)
- planner.assignee_upn: string (任意, 1名固定)
- planner.assignee_upns: string array または comma-separated string (任意)

補足:

- assignee_upn 指定時はその 1 名を優先
- assignee_upns 指定時はその一覧を使用
- どちらも未指定なら upns 全員を割り当て

## 4. 最小リクエスト例

```json
{
  "upns": [
    "analyst01@contoso.com",
    "owner01@contoso.com"
  ],
  "title": "脆弱性通知: CVE-2026-12345",
  "message": "OpenSSL の重大脆弱性を検知しました。"
}
```

## 5. Planner 有効リクエスト例

```json
{
  "upns": [
    "analyst01@contoso.com",
    "owner01@contoso.com",
    "manager01@contoso.com"
  ],
  "title": "脆弱性通知: CVE-2026-12345",
  "message": "OpenSSL の重大脆弱性を検知しました。",
  "facts": {
    "cve_id": "CVE-2026-12345",
    "severity": "High",
    "cvss": "9.1",
    "component": "OpenSSL",
    "due_date": "2026-04-13"
  },
  "planner": {
    "enabled": true,
    "plan_id": "<PLANNER_PLAN_ID>",
    "bucket_id": "<PLANNER_BUCKET_ID>"
  }
}
```

## 6. Planner ID / Bucket ID の取得

Planner 連携を有効化する場合は、`plan_id` と `bucket_id` を事前に取得してください。

### 6-1. Graph トークンを取得

```powershell
$graphToken = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
$graphHeaders = @{ Authorization = "Bearer $graphToken" }
```

### 6-2. 利用可能な Plan を取得

```powershell
az rest \
  --method GET \
  --url "https://graph.microsoft.com/v1.0/me/planner/plans" \
  --headers "Authorization=Bearer $graphToken" \
  --output json
```

- `value[].id` が `plan_id`
- `value[].title` が Plan 名

### 6-3. Plan の Bucket 一覧を取得

```powershell
$planId = "<PLAN_ID>"

az rest \
  --method GET \
  --url "https://graph.microsoft.com/v1.0/planner/plans/$planId/buckets" \
  --headers "Authorization=Bearer $graphToken" \
  --output json
```

- `value[].id` が `bucket_id`
- `value[].name` が Bucket 名

### 6-4. PowerShell で見やすく表示（任意）

```powershell
$plans = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/me/planner/plans" -Headers $graphHeaders
$plans.value | Select-Object id,title,owner | Format-Table -AutoSize

$planId = "<PLAN_ID>"
$buckets = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/planner/plans/$planId/buckets" -Headers $graphHeaders
$buckets.value | Select-Object id,name,orderHint | Format-Table -AutoSize
```

## 7. PowerShell 送信例

```powershell
$body = @{
  upns = @(
    "analyst01@contoso.com",
    "owner01@contoso.com"
  )
  title = "脆弱性通知: CVE-2026-12345"
  message = "OpenSSL の重大脆弱性を検知しました。"
} | ConvertTo-Json -Depth 8

$headers = @{
  "x-api-key" = $apiKey
  "Authorization" = "Bearer $token"
  "Content-Type" = "application/json"
}

Invoke-RestMethod -Method POST -Uri $notifyUrl -Headers $headers -Body $body
```

## 8. レスポンス仕様

### 7-1. 正常 (200)

```json
{
  "status": "sent",
  "chat_id": "19:...",
  "message_id": "1712...",
  "target_upns": [
    "analyst01@contoso.com",
    "owner01@contoso.com"
  ],
  "planner_task_id": "flWsCYSX9EKwp-Jvekh03WUAOkae"
}
```

planner が無効な場合、planner_task_id は含まれません。

### 7-2. 部分成功 (207)

- チャット投稿は成功
- Planner 作成で失敗

```json
{
  "status": "sent",
  "chat_id": "19:...",
  "message_id": "1712...",
  "target_upns": ["..."],
  "planner_error": "..."
}
```

## 9. 代表的なエラー

- 401 Unauthorized
  - x-api-key 不一致
  - Authorization ヘッダー不足
  - OBO token acquisition failed
- 400 Bad Request
  - JSON 不正
  - upn/upns 未指定
  - chat_id 未指定かつ upns が 1 件
  - UPN 解決失敗
- 500 Internal Server Error
  - チャット作成失敗
  - チャット投稿失敗

## 10. 実装の推奨事項

- リトライは 429/5xx のみ指数バックオフで実施
- 同一通知の重複送信を防ぐため、送信側で idempotency キーを管理
- 機密情報 (API key, token) をログに出力しない

## 11. 参照

- E2E テストスクリプト: Test-VulnNotify.ps1
- 運用手順: RUNBOOK.md
- 全体ガイド: ../README.md
