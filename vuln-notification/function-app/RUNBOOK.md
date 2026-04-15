# vuln-notify Function Runbook (OBO / Delegated)

## 1. 現在のアーキテクチャ
- Function エンドポイント: `POST /api/notify`
- Function -> Graph 認証: OBO (委任権限)
- API 側アプリ: `vuln-notify-api-app` (`<API_APP_ID>`)
- クライアント側アプリ: `vuln-notify-client-app` (`<CLIENT_APP_ID>`)

## 2. 必須の Entra 設定
### API 側アプリ (`vuln-notify-api-app`)
- Expose an API:
  - Application ID URI: `api://<API_APP_ID>`
  - Scope: `access_as_user`
- Graph 委任権限:
  - `Chat.Create`
  - `ChatMessage.Send`
  - `Tasks.ReadWrite`
  - `User.ReadBasic.All`
- 管理者同意: 付与済み

### クライアント側アプリ (`vuln-notify-client-app`)
- API 側スコープへの Delegated 権限:
  - `access_as_user`
- 管理者同意: 付与済み

## 3. Key Vault 必須シークレット
`kv-vuln-notify-prod` に以下を登録:
- `TENANT-ID`
- `CLIENT-ID` (値: `<API_APP_ID>`)
- `CLIENT-SECRET` (`vuln-notify-api-app` のシークレット)

## 4. Function コードのデプロイ
```powershell
Push-Location function-app
func azure functionapp publish func-vuln-notify-prod --python --build remote
Pop-Location
```

## 5. Key Vault 参照の反映 + 再起動
```powershell
az rest --method POST --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/vuln-notify-rg/providers/Microsoft.Web/sites/func-vuln-notify-prod/config/configreferences/appsettings/refresh?api-version=2022-03-01"
az functionapp restart -g vuln-notify-rg -n func-vuln-notify-prod
```

## 6. E2E テスト
### 6.1 対話ログイン (必要時)
```powershell
az logout
az login --tenant "<TENANT_ID>" --scope "api://<API_APP_ID>/access_as_user"
```

### 6.2 通知のみテスト
```powershell
$token = az account get-access-token --scope "api://<API_APP_ID>/access_as_user" --query accessToken -o tsv
.\function-app\Test-VulnNotify.ps1 -UserAccessToken $token -Upns "analyst01@contoso.com","owner01@contoso.com","manager01@contoso.com"
```

### 6.3 Planner 連携テスト
```powershell
$token = az account get-access-token --scope "api://<API_APP_ID>/access_as_user" --query accessToken -o tsv
.\function-app\Test-VulnNotify.ps1 -UserAccessToken $token -Upns "analyst01@contoso.com","owner01@contoso.com","manager01@contoso.com" -CreatePlannerTask -PlannerPlanId "<PLANNER_PLAN_ID>" -PlannerBucketId "<PLANNER_BUCKET_ID>"
```

## 7. Planner 担当者割り当て仕様
- 既定: `upns` に含まれる全ユーザーを担当者に割り当て
- `planner.assignee_upn` 指定時: その 1 名のみ割り当て
- `planner.assignee_upns` 指定時: 指定した複数ユーザーを割り当て

## 8. 期待される成功レスポンス
- `[OK] 通知送信成功`
- レスポンスに以下が含まれる:
  - `status: sent`
  - `chat_id`
  - `message_id`
  - `target_upns`
  - `planner_task_id` (Planner 有効時)

## 9. よくあるエラー
- `AADSTS65001 consent_required`
  - クライアント/API スコープ、または Graph 委任権限の同意不足
- `AADSTS700016 application not found`
  - `CLIENT-ID` が誤ったアプリ登録を参照
- `403 Missing scope permissions` (`/chats`)
  - トークンに `Chat.Create` が不足
- `401` (`/messages`)
  - `ChatMessage.Send` が未同意、またはトークン audience 不一致
- `403` (`/planner/tasks`)
  - `Tasks.ReadWrite` が未同意
