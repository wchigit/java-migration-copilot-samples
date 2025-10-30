# Asset Manager - Azure Infrastructure Provisioning Script (PowerShell)
# This script provisions all Azure resources needed for the Asset Manager application
# Target Region: northeurope

$ErrorActionPreference = "Stop"  # Exit on any error

# Configuration Variables
$ResourceToken = -join ((48..57) + (97..122) | Get-Random -Count 5 | ForEach-Object {[char]$_})
$Location = "northeurope"
$SubscriptionId = "a4ab3025-1b32-4394-92e0-d07c1ebf3787"

# Resource Names (following naming convention: {prefix}{token}{instance})
$ResourceGroupName = "rg$ResourceToken"
$AksClusterName = "aks$ResourceToken"
$AcrName = "acr$ResourceToken"
$PostgresServerName = "pg$ResourceToken"
$StorageAccountName = "st$ResourceToken"
$ServiceBusName = "sb$ResourceToken"
$KeyVaultName = "kv$ResourceToken"
$AppInsightsName = "ai$ResourceToken"
$LogAnalyticsName = "la$ResourceToken"
$ManagedIdentityName = "id$ResourceToken"

# Database Configuration
$PostgresAdminUsername = "assetadmin"
$PostgresDatabaseName = "assets_manager"
$ServiceBusQueueName = "image-processing"
$StorageContainerName = "images"

Write-Host "Starting Azure Infrastructure Provisioning for Asset Manager..." -ForegroundColor Green
Write-Host "Resource Token: $ResourceToken" -ForegroundColor Yellow
Write-Host "Target Location: $Location" -ForegroundColor Yellow
Write-Host "Subscription: $SubscriptionId" -ForegroundColor Yellow

# Set the subscription
Write-Host "Setting Azure subscription..." -ForegroundColor Cyan
az account set --subscription $SubscriptionId

# Create Resource Group
Write-Host "Creating Resource Group: $ResourceGroupName..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --tags "project=asset-manager" "environment=production"

# Create User-Assigned Managed Identity
Write-Host "Creating User-Assigned Managed Identity: $ManagedIdentityName..." -ForegroundColor Cyan
az identity create --resource-group $ResourceGroupName --name $ManagedIdentityName --location $Location

# Get Managed Identity details
$IdentityId = az identity show --resource-group $ResourceGroupName --name $ManagedIdentityName --query id -o tsv
$IdentityClientId = az identity show --resource-group $ResourceGroupName --name $ManagedIdentityName --query clientId -o tsv
$IdentityPrincipalId = az identity show --resource-group $ResourceGroupName --name $ManagedIdentityName --query principalId -o tsv

Write-Host "Identity ID: $IdentityId" -ForegroundColor Yellow
Write-Host "Identity Client ID: $IdentityClientId" -ForegroundColor Yellow
Write-Host "Identity Principal ID: $IdentityPrincipalId" -ForegroundColor Yellow

# Create Log Analytics Workspace
Write-Host "Creating Log Analytics Workspace: $LogAnalyticsName..." -ForegroundColor Cyan
az monitor log-analytics workspace create --resource-group $ResourceGroupName --workspace-name $LogAnalyticsName --location $Location --sku "PerGB2018"

# Get Log Analytics Workspace ID
$LogAnalyticsId = az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $LogAnalyticsName --query id -o tsv

# Create Application Insights
Write-Host "Creating Application Insights: $AppInsightsName..." -ForegroundColor Cyan
az monitor app-insights component create --app $AppInsightsName --location $Location --resource-group $ResourceGroupName --workspace $LogAnalyticsId

# Create Azure Container Registry
Write-Host "Creating Azure Container Registry: $AcrName..." -ForegroundColor Cyan
az acr create --resource-group $ResourceGroupName --name $AcrName --sku "Basic" --location $Location --admin-enabled false

# Wait for ACR to be fully provisioned
Start-Sleep -Seconds 30

# Assign AcrPull role to Managed Identity
Write-Host "Assigning AcrPull role to Managed Identity..." -ForegroundColor Cyan
$AcrResourceId = az acr show --resource-group $ResourceGroupName --name $AcrName --query id -o tsv
az role assignment create --assignee $IdentityPrincipalId --role "7f951dda-4ed3-4680-a7ca-43fe172d538d" --scope $AcrResourceId

# Create Azure Kubernetes Service
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
  --kubernetes-version "1.28"

# Create Storage Account
Write-Host "Creating Storage Account: $StorageAccountName..." -ForegroundColor Cyan
az storage account create --resource-group $ResourceGroupName --name $StorageAccountName --location $Location --sku "Standard_LRS" --kind "StorageV2" --access-tier "Hot"

# Create blob container
Write-Host "Creating blob container: $StorageContainerName..." -ForegroundColor Cyan
az storage container create --account-name $StorageAccountName --name $StorageContainerName --auth-mode login

# Assign Storage Blob Data Contributor role to Managed Identity
Write-Host "Assigning Storage Blob Data Contributor role to Managed Identity..." -ForegroundColor Cyan
$StorageResourceId = az storage account show --resource-group $ResourceGroupName --name $StorageAccountName --query id -o tsv
az role assignment create --assignee $IdentityPrincipalId --role "ba92f5b4-2d11-453d-a403-e96b0029c9fe" --scope $StorageResourceId

# Create PostgreSQL Flexible Server
Write-Host "Creating PostgreSQL Flexible Server: $PostgresServerName..." -ForegroundColor Cyan
az postgres flexible-server create `
  --resource-group $ResourceGroupName `
  --name $PostgresServerName `
  --location $Location `
  --admin-user $PostgresAdminUsername `
  --admin-password "P@ssw0rd123!" `
  --sku-name "Standard_B1ms" `
  --tier "Burstable" `
  --storage-size 32 `
  --version 15 `
  --public-access "All"

# Create database
Write-Host "Creating database: $PostgresDatabaseName..." -ForegroundColor Cyan
az postgres flexible-server db create --resource-group $ResourceGroupName --server-name $PostgresServerName --database-name $PostgresDatabaseName

# Create Service Bus Namespace
Write-Host "Creating Service Bus Namespace: $ServiceBusName..." -ForegroundColor Cyan
az servicebus namespace create --resource-group $ResourceGroupName --name $ServiceBusName --location $Location --sku "Standard"

# Create Service Bus Queue
Write-Host "Creating Service Bus Queue: $ServiceBusQueueName..." -ForegroundColor Cyan
az servicebus queue create --resource-group $ResourceGroupName --namespace-name $ServiceBusName --name $ServiceBusQueueName --max-size 1024

# Assign Service Bus Data Owner role to Managed Identity
Write-Host "Assigning Service Bus Data Owner role to Managed Identity..." -ForegroundColor Cyan
$ServiceBusResourceId = az servicebus namespace show --resource-group $ResourceGroupName --name $ServiceBusName --query id -o tsv
az role assignment create --assignee $IdentityPrincipalId --role "090c5cfd-751d-490a-894a-3ce6f1109419" --scope $ServiceBusResourceId

# Create Key Vault
Write-Host "Creating Key Vault: $KeyVaultName..." -ForegroundColor Cyan
az keyvault create --resource-group $ResourceGroupName --name $KeyVaultName --location $Location --sku "standard" --enable-rbac-authorization true

# Assign Key Vault Secrets User role to Managed Identity
Write-Host "Assigning Key Vault Secrets User role to Managed Identity..." -ForegroundColor Cyan
$KeyVaultResourceId = az keyvault show --resource-group $ResourceGroupName --name $KeyVaultName --query id -o tsv
az role assignment create --assignee $IdentityPrincipalId --role "4633458b-17de-408a-b874-0445c86b69e6" --scope $KeyVaultResourceId

# Store connection strings in Key Vault
Write-Host "Storing connection strings in Key Vault..." -ForegroundColor Cyan
$PostgresConnectionString = "Host=$PostgresServerName.postgres.database.azure.com;Database=$PostgresDatabaseName;Username=$PostgresAdminUsername;Password=P@ssw0rd123!;Port=5432;SSL Mode=Require;"
az keyvault secret set --vault-name $KeyVaultName --name "postgres-connection-string" --value $PostgresConnectionString

# Get AKS credentials
Write-Host "Getting AKS credentials..." -ForegroundColor Cyan
az aks get-credentials --resource-group $ResourceGroupName --name $AksClusterName --overwrite-existing

# Output summary
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "Azure Infrastructure Provisioning Complete!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Yellow
Write-Host "AKS Cluster: $AksClusterName" -ForegroundColor Yellow
Write-Host "Container Registry: $AcrName" -ForegroundColor Yellow
Write-Host "PostgreSQL Server: $PostgresServerName" -ForegroundColor Yellow
Write-Host "Storage Account: $StorageAccountName" -ForegroundColor Yellow
Write-Host "Service Bus: $ServiceBusName" -ForegroundColor Yellow
Write-Host "Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host "Managed Identity: $ManagedIdentityName" -ForegroundColor Yellow
Write-Host "Identity Client ID: $IdentityClientId" -ForegroundColor Yellow
Write-Host ""
Write-Host "Environment Variables for Applications:" -ForegroundColor Cyan
Write-Host "AZURE_CLIENT_ID=$IdentityClientId"
Write-Host "AZURE_STORAGE_ACCOUNT_NAME=$StorageAccountName"
Write-Host "AZURE_STORAGE_BLOB_CONTAINER_NAME=$StorageContainerName"
Write-Host "AZURE_SERVICEBUS_NAMESPACE=$ServiceBusName"
Write-Host "SPRING_DATASOURCE_URL=jdbc:postgresql://$PostgresServerName.postgres.database.azure.com:5432/$PostgresDatabaseName?sslmode=require"
Write-Host "SPRING_DATASOURCE_USERNAME=$PostgresAdminUsername"
Write-Host "SPRING_DATASOURCE_PASSWORD=P@ssw0rd123!"
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "1. Build and push container images to ACR"
Write-Host "2. Deploy Kubernetes manifests to AKS"
Write-Host "3. Configure application environment variables"
Write-Host "==========================================" -ForegroundColor Green

# Save environment variables to file
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
AZURE_STORAGE_BLOB_CONTAINER_NAME=$StorageContainerName
AZURE_SERVICEBUS_NAMESPACE=$ServiceBusName
SPRING_DATASOURCE_URL=jdbc:postgresql://$PostgresServerName.postgres.database.azure.com:5432/$PostgresDatabaseName?sslmode=require
SPRING_DATASOURCE_USERNAME=$PostgresAdminUsername
SPRING_DATASOURCE_PASSWORD=P@ssw0rd123!
"@ | Out-File -FilePath ".azure\environment-variables.env" -Encoding UTF8

Write-Host "Environment variables saved to .azure\environment-variables.env" -ForegroundColor Green