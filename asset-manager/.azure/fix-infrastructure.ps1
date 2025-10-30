# Asset Manager - Infrastructure Fix Script (PowerShell)
# This script fixes the infrastructure provisioning issues

$ErrorActionPreference = "Stop"

# Load environment variables
$ResourceToken = "ie6nt"
$ResourceGroupName = "rgie6nt"
$AksClusterName = "aksie6nt"
$AcrName = "acrie6nt"
$PostgresServerName = "pgie6nt"
$StorageAccountName = "stie6nt"
$ServiceBusName = "sbie6nt"
$KeyVaultName = "kvie6nt"
$ManagedIdentityName = "idie6nt"
$Location = "northeurope"
$PostgresAdminUsername = "assetadmin"
$PostgresDatabaseName = "assets_manager"

Write-Host "Fixing infrastructure provisioning issues..." -ForegroundColor Green

# Get Managed Identity details
$IdentityId = az identity show --resource-group $ResourceGroupName --name $ManagedIdentityName --query id -o tsv
$IdentityClientId = az identity show --resource-group $ResourceGroupName --name $ManagedIdentityName --query clientId -o tsv
$IdentityPrincipalId = az identity show --resource-group $ResourceGroupName --name $ManagedIdentityName --query principalId -o tsv

Write-Host "Identity Client ID: $IdentityClientId" -ForegroundColor Yellow

# Get Log Analytics Workspace ID
$LogAnalyticsId = az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name "laie6nt" --query id -o tsv

# Recreate AKS Cluster with SSH key generation
Write-Host "Creating AKS Cluster: $AksClusterName..." -ForegroundColor Cyan
az aks create `
  --resource-group $ResourceGroupName `
  --name $AksClusterName `
  --location $Location `
  --node-count 2 `
  --node-vm-size "Standard_B2ms" `
  --enable-managed-identity `
  --assign-identity $IdentityId `
  --attach-acr $AcrName `
  --enable-addons monitoring `
  --workspace-resource-id $LogAnalyticsId `
  --kubernetes-version "1.28" `
  --generate-ssh-keys

Write-Host "AKS Cluster created successfully!" -ForegroundColor Green

# Give the current user Key Vault Administrator role for now (to store secrets)
Write-Host "Assigning Key Vault Administrator role to current user..." -ForegroundColor Cyan
$CurrentUserId = az ad signed-in-user show --query id -o tsv
$KeyVaultResourceId = az keyvault show --resource-group $ResourceGroupName --name $KeyVaultName --query id -o tsv
az role assignment create --assignee $CurrentUserId --role "00482a5a-887f-4fb3-b363-3b7fe8e74483" --scope $KeyVaultResourceId

# Wait for role assignment to propagate
Write-Host "Waiting for role assignment to propagate..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# Store connection strings in Key Vault
Write-Host "Storing connection strings in Key Vault..." -ForegroundColor Cyan
$PostgresConnectionString = "Host=$PostgresServerName.postgres.database.azure.com;Database=$PostgresDatabaseName;Username=$PostgresAdminUsername;Password=P@ssw0rd123!;Port=5432;SSL Mode=Require;"

try {
    az keyvault secret set --vault-name $KeyVaultName --name "postgres-connection-string" --value $PostgresConnectionString
    Write-Host "Successfully stored connection string in Key Vault" -ForegroundColor Green
} catch {
    Write-Host "Warning: Could not store connection string in Key Vault. Will use environment variables instead." -ForegroundColor Yellow
}

# Get AKS credentials
Write-Host "Getting AKS credentials..." -ForegroundColor Cyan
az aks get-credentials --resource-group $ResourceGroupName --name $AksClusterName --overwrite-existing

Write-Host "Infrastructure fix completed successfully!" -ForegroundColor Green

# Update environment variables file with correct database URL
$DatabaseUrl = "jdbc:postgresql://$PostgresServerName.postgres.database.azure.com:5432/$PostgresDatabaseName?sslmode=require"

@"
RESOURCE_TOKEN=$ResourceToken
RESOURCE_GROUP_NAME=$ResourceGroupName
AKS_CLUSTER_NAME=$AksClusterName
ACR_NAME=$AcrName
POSTGRES_SERVER_NAME=$PostgresServerName
STORAGE_ACCOUNT_NAME=$StorageAccountName
SERVICE_BUS_NAME=$ServiceBusName
KEY_VAULT_NAME=$KeyVaultName
MANAGED_IDENTITY_NAME=$ManagedIdentityName
AZURE_CLIENT_ID=$IdentityClientId
AZURE_STORAGE_ACCOUNT_NAME=$StorageAccountName
AZURE_STORAGE_BLOB_CONTAINER_NAME=images
AZURE_SERVICEBUS_NAMESPACE=$ServiceBusName
SPRING_DATASOURCE_URL=$DatabaseUrl
SPRING_DATASOURCE_USERNAME=$PostgresAdminUsername
SPRING_DATASOURCE_PASSWORD=P@ssw0rd123!
"@ | Out-File -FilePath ".azure\environment-variables.env" -Encoding UTF8

Write-Host "Updated environment variables saved to .azure\environment-variables.env" -ForegroundColor Green