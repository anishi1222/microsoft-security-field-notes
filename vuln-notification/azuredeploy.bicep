// ============================================================
// 脆弱性通知システム - Bicep テンプレート
// リソース: Storage / Log Analytics / App Insights /
//           App Service Plan / Function App / Key Vault /
//           Role Assignment (Key Vault Secrets User)
// ============================================================

@description('リソースのデプロイ先リージョン')
param location string = resourceGroup().location

@description('Function App のベース名（サフィックスは自動付与）')
param functionAppBaseName string

@description('Key Vault のベース名（サフィックスは自動付与）')
param keyVaultBaseName string

@description('名前サフィックス。空の場合は resourceGroup().id 由来の6文字を自動採用')
param nameSuffix string = ''

// ── 変数 ────────────────────────────────────────────────────
var storageAccountName        = 'st${uniqueString(resourceGroup().id)}'
var effectiveSuffix           = empty(nameSuffix) ? toLower(substring(uniqueString(resourceGroup().id), 0, 6)) : toLower(nameSuffix)
var functionAppName           = '${functionAppBaseName}-${effectiveSuffix}'
var keyVaultBaseNormalized    = toLower(replace(keyVaultBaseName, '-', ''))
var keyVaultName              = '${substring(keyVaultBaseNormalized, 0, min(length(keyVaultBaseNormalized), 18))}${effectiveSuffix}'
var appServicePlanName        = '${functionAppName}-plan'
var appInsightsName           = '${functionAppName}-ai'
var logAnalyticsName          = '${functionAppName}-law'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// ── 1. Storage Account ──────────────────────────────────────
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

// ── 2. Log Analytics Workspace ──────────────────────────────
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
  }
}

// ── 3. Application Insights ─────────────────────────────────
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ── 4. App Service Plan（従量課金・Linux）──────────────────
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true
  }
}

// ── 5. Function App（Managed Identity 付き・Linux）─────────
resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        // ── Key Vault 参照（Managed Identity で自動解決）──
        {
          name: 'TENANT_ID'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=TENANT-ID)'
        }
        {
          name: 'CLIENT_ID'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=CLIENT-ID)'
        }
        {
          name: 'CLIENT_SECRET'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=CLIENT-SECRET)'
        }
      ]
    }
  }
}

// ── 6. Key Vault ────────────────────────────────────────────
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// ── 7. Role Assignment（Key Vault Secrets User）────────────
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.name, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── 出力 ────────────────────────────────────────────────────
output functionAppUrl             string = 'https://${functionApp.properties.defaultHostName}'
output keyVaultName               string = keyVault.name
output managedIdentityPrincipalId string = functionApp.identity.principalId
