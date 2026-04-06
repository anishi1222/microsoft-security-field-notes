# ==============================================================
# 脆弱性通知システム - 動作確認用 PowerShell スクリプト
# 使用方法:
#   .\function-app\Test-VulnNotify.ps1 -FunctionAppName "<FUNCTION_APP_NAME>" -ApiKey "xxx" -UserAccessToken "<Entra user token>" -Upns "analyst01@contoso.com","owner01@contoso.com"
#   .\function-app\Test-VulnNotify.ps1 -FunctionAppName "<FUNCTION_APP_NAME>" -ApiKey "xxx" -UseAzGraphToken -Upns "analyst01@contoso.com","owner01@contoso.com"
#   .\function-app\Test-VulnNotify.ps1 -FunctionAppName "<FUNCTION_APP_NAME>" -ApiKey "xxx" -UseAzGraphToken -Upns "analyst01@contoso.com","owner01@contoso.com" -CreatePlannerTask -PlannerPlanId "<PLANNER_PLAN_ID>" -PlannerBucketId "<PLANNER_BUCKET_ID>"
# ==============================================================

param (
    [string] $FunctionAppName = "",
    [string] $FunctionUrl = "",
    [string] $ApiKey      = "",
    [string] $UserAccessToken = "",
    [switch] $UseAzGraphToken,
    [string[]] $Upns = @(),
    [string] $ChatId = "",
    [switch] $CreatePlannerTask,
    [string] $PlannerPlanId = "",
    [string] $PlannerBucketId = "",
    [string] $PlannerAssigneeUpn = "",
    [string] $Title = "Entra 通知",
    [string] $Message = "HTTP トリガーからの通知です。"
)

if (-not $FunctionUrl -and -not $FunctionAppName) {
    Write-Host "[ERROR] FunctionUrl または FunctionAppName を指定してください。公開用サンプルのため既定値は設定していません。" -ForegroundColor Red
    exit 1
}

if (-not $FunctionUrl) {
    $FunctionUrl = "https://$FunctionAppName.azurewebsites.net/api/notify"
}

if (-not $ApiKey) {
    $ApiKey = $env:VULN_NOTIFY_API_KEY
}
if ($Upns.Count -eq 0 -and $env:VULN_NOTIFY_UPNS) {
    $Upns = $env:VULN_NOTIFY_UPNS.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
if (-not $PlannerPlanId) {
    $PlannerPlanId = $env:VULN_NOTIFY_PLANNER_PLAN_ID
}
if (-not $PlannerBucketId) {
    $PlannerBucketId = $env:VULN_NOTIFY_PLANNER_BUCKET_ID
}
if (-not $PlannerAssigneeUpn) {
    $PlannerAssigneeUpn = $env:VULN_NOTIFY_PLANNER_ASSIGNEE_UPN
}

if (-not $ApiKey) {
    Write-Host "[ERROR] ApiKey が未指定です。-ApiKey または VULN_NOTIFY_API_KEY を設定してください。" -ForegroundColor Red
    exit 1
}

if (-not $UserAccessToken) {
    $UserAccessToken = $env:VULN_NOTIFY_USER_TOKEN
}

if (-not $UserAccessToken -and $UseAzGraphToken) {
    $UserAccessToken = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
}

if (-not $UserAccessToken) {
    Write-Host "[ERROR] UserAccessToken が未指定です。-UserAccessToken / VULN_NOTIFY_USER_TOKEN / -UseAzGraphToken を利用してください。" -ForegroundColor Red
    exit 1
}

if ($Upns.Count -eq 0) {
    Write-Host "[ERROR] UPN が未指定です。-Upns または VULN_NOTIFY_UPNS(カンマ区切り)を設定してください。" -ForegroundColor Red
    exit 1
}

if ($CreatePlannerTask -and (-not $PlannerPlanId -or -not $PlannerBucketId)) {
    Write-Host "[ERROR] Planner タスク作成には -PlannerPlanId と -PlannerBucketId が必要です。" -ForegroundColor Red
    exit 1
}

# ── サンプル脆弱性情報 ─────────────────────────────────────────
$SampleVulnerability = @{
    cve_id = "CVE-2026-12345"
    severity = "High"
    cvss = "9.1"
    component = "OpenSSL"
    affected_version = "3.0.0 - 3.0.13"
    fixed_version = "3.0.14"
    service = "payments-api"
    environment = "production"
    due_date = (Get-Date).AddDays(7).ToString("yyyy-MM-dd")
    reference = "https://nvd.nist.gov/vuln/detail/CVE-2026-12345"
}

if ($Title -eq "Entra 通知") {
    $Title = "脆弱性通知: $($SampleVulnerability.cve_id)"
}

if ($Message -eq "HTTP トリガーからの通知です。") {
    $Message = "$($SampleVulnerability.component) の重大脆弱性を検知しました。修正期限: $($SampleVulnerability.due_date)"
}

# ── テスト用パラメーター ────────────────────────────────────────
$PlannerAssigneeUpns = @()
if ($PlannerAssigneeUpn) {
    $PlannerAssigneeUpns = @($PlannerAssigneeUpn)
} else {
    $PlannerAssigneeUpns = $Upns
}

$Payload = @{
    upns = $Upns
    chat_id = $ChatId
    title = $Title
    message = $Message
    planner = @{
        enabled = [bool]$CreatePlannerTask
        plan_id = $PlannerPlanId
        bucket_id = $PlannerBucketId
        assignee_upn = $PlannerAssigneeUpn
        assignee_upns = $PlannerAssigneeUpns
    }
    facts = @{
        source = "Test-VulnNotify.ps1"
        targetUserCount = $Upns.Count
        cve_id = $SampleVulnerability.cve_id
        severity = $SampleVulnerability.severity
        cvss = $SampleVulnerability.cvss
        component = $SampleVulnerability.component
        affected_version = $SampleVulnerability.affected_version
        fixed_version = $SampleVulnerability.fixed_version
        service = $SampleVulnerability.service
        environment = $SampleVulnerability.environment
        due_date = $SampleVulnerability.due_date
        reference = $SampleVulnerability.reference
    }
}

# ── リクエスト送信 ──────────────────────────────────────────────
$Headers = @{
    "Content-Type" = "application/json"
    "x-api-key"    = $ApiKey
    "Authorization" = "Bearer $UserAccessToken"
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  脆弱性通知システム - 動作確認" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  送信先  : $FunctionUrl"
Write-Host "  UPN数   : $($Upns.Count)"
Write-Host "  chat_id : $(if($ChatId){$ChatId}else{'(新規作成)'})"
Write-Host "  Planner : $(if($CreatePlannerTask){'有効'}else{'無効'})"
if ($CreatePlannerTask) {
    Write-Host "  PlanId  : $PlannerPlanId"
    Write-Host "  BucketId: $PlannerBucketId"
}
Write-Host "------------------------------------------------" -ForegroundColor Cyan

try {
    $Response = Invoke-RestMethod `
        -Uri     $FunctionUrl `
        -Method  POST `
        -Headers $Headers `
        -Body    ($Payload | ConvertTo-Json -Depth 10) `
        -ErrorAction Stop

    Write-Host ""
    Write-Host "[OK] 通知送信成功" -ForegroundColor Green
    Write-Host "  レスポンス: $($Response | ConvertTo-Json -Compress)"

} catch {
    $StatusCode = $_.Exception.Response.StatusCode.value__
    $Message    = $_.ErrorDetails.Message

    Write-Host ""
    Write-Host "[ERROR] 送信失敗 (HTTP $StatusCode)" -ForegroundColor Red
    Write-Host "  詳細: $Message"
}

Write-Host ""
