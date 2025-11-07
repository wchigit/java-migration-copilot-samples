# Azure Asset Manager Deployment Script
# This script provisions all required Azure resources for the Asset Manager application on AKS

$ErrorActionPreference = "Stop"

# Configuration variables
$LOCATION = "westus3"
$RESOURCE_TOKEN = -join ((1..4) | ForEach {Get-Random -Input ([char[]](97..122))})  # 4 character random string
$CURRENT_USER = (az account show --query user.name -o tsv)

# Resource names using naming convention: {prefix}{token}{instance}
$RG_NAME = "rg$RESOURCE_TOKEN"
$AKS_NAME = "aks$RESOURCE_TOKEN"
$ACR_NAME = "acr$RESOURCE_TOKEN"
$KV_NAME = "kv$RESOURCE_TOKEN"
$POSTGRES_NAME = "psql$RESOURCE_TOKEN"
$SERVICEBUS_NAME = "sb$RESOURCE_TOKEN"
$STORAGE_NAME = "st$RESOURCE_TOKEN"
$LOG_WORKSPACE_NAME = "log$RESOURCE_TOKEN"
$APP_INSIGHTS_NAME = "ai$RESOURCE_TOKEN"
$MANAGED_IDENTITY_NAME = "id$RESOURCE_TOKEN"

# Database configuration
$DB_NAME = "assetdb"
$DB_USERNAME = "assetadmin"

Write-Host "Starting Azure resource provisioning..." -ForegroundColor Green
Write-Host "Resource Token: $RESOURCE_TOKEN" -ForegroundColor Yellow
Write-Host "Location: $LOCATION" -ForegroundColor Yellow

# Check if resource group exists, create if not
Write-Host "Creating resource group..." -ForegroundColor Cyan
try {
    az group show --name $RG_NAME --output none 2>$null
    Write-Host "Resource group $RG_NAME already exists" -ForegroundColor Yellow
} catch {
    az group create --name $RG_NAME --location $LOCATION
    Write-Host "Resource group $RG_NAME created" -ForegroundColor Green
}

# Create Log Analytics Workspace
Write-Host "Creating Log Analytics Workspace..." -ForegroundColor Cyan
try {
    az monitor log-analytics workspace show --resource-group $RG_NAME --workspace-name $LOG_WORKSPACE_NAME --output none 2>$null
    Write-Host "Log Analytics Workspace $LOG_WORKSPACE_NAME already exists" -ForegroundColor Yellow
} catch {
    az monitor log-analytics workspace create --resource-group $RG_NAME --workspace-name $LOG_WORKSPACE_NAME --location $LOCATION
    Write-Host "Log Analytics Workspace $LOG_WORKSPACE_NAME created" -ForegroundColor Green
}

# Create Application Insights
Write-Host "Creating Application Insights..." -ForegroundColor Cyan
try {
    az monitor app-insights component show --app $APP_INSIGHTS_NAME --resource-group $RG_NAME --output none 2>$null
    Write-Host "Application Insights $APP_INSIGHTS_NAME already exists" -ForegroundColor Yellow
} catch {
    $WORKSPACE_ID = (az monitor log-analytics workspace show --resource-group $RG_NAME --workspace-name $LOG_WORKSPACE_NAME --query id -o tsv)
    az monitor app-insights component create --app $APP_INSIGHTS_NAME --location $LOCATION --resource-group $RG_NAME --workspace $WORKSPACE_ID
    Write-Host "Application Insights $APP_INSIGHTS_NAME created" -ForegroundColor Green
}

# Create User-Assigned Managed Identity
Write-Host "Creating User-Assigned Managed Identity..." -ForegroundColor Cyan
try {
    az identity show --resource-group $RG_NAME --name $MANAGED_IDENTITY_NAME --output none 2>$null
    Write-Host "Managed Identity $MANAGED_IDENTITY_NAME already exists" -ForegroundColor Yellow
} catch {
    az identity create --resource-group $RG_NAME --name $MANAGED_IDENTITY_NAME
    Write-Host "Managed Identity $MANAGED_IDENTITY_NAME created" -ForegroundColor Green
}

# Get managed identity details
$MANAGED_IDENTITY_ID = (az identity show --resource-group $RG_NAME --name $MANAGED_IDENTITY_NAME --query id -o tsv)
$MANAGED_IDENTITY_CLIENT_ID = (az identity show --resource-group $RG_NAME --name $MANAGED_IDENTITY_NAME --query clientId -o tsv)
$MANAGED_IDENTITY_PRINCIPAL_ID = (az identity show --resource-group $RG_NAME --name $MANAGED_IDENTITY_NAME --query principalId -o tsv)

# Create Container Registry
Write-Host "Creating Azure Container Registry..." -ForegroundColor Cyan
try {
    az acr show --name $ACR_NAME --resource-group $RG_NAME --output none 2>$null
    Write-Host "Container Registry $ACR_NAME already exists" -ForegroundColor Yellow
} catch {
    az acr create --name $ACR_NAME --resource-group $RG_NAME --sku Standard --location $LOCATION
    Write-Host "Container Registry $ACR_NAME created" -ForegroundColor Green
}

# Create Key Vault with RBAC
Write-Host "Creating Key Vault..." -ForegroundColor Cyan
try {
    az keyvault show --name $KV_NAME --resource-group $RG_NAME --output none 2>$null
    Write-Host "Key Vault $KV_NAME already exists" -ForegroundColor Yellow
} catch {
    az keyvault create --name $KV_NAME --resource-group $RG_NAME --location $LOCATION --enable-rbac-authorization true --default-action Allow --bypass AzureServices
    Write-Host "Key Vault $KV_NAME created" -ForegroundColor Green
}

# Assign Key Vault Secrets Officer role to current user
Write-Host "Assigning Key Vault Secrets Officer role to current user..." -ForegroundColor Cyan
$CURRENT_USER_OBJECT_ID = (az ad signed-in-user show --query id -o tsv)
$SUBSCRIPTION_ID = (az account show --query id -o tsv)
try {
    az role assignment create --role "Key Vault Secrets Officer" --assignee $CURRENT_USER_OBJECT_ID --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.KeyVault/vaults/$KV_NAME" --output none 2>$null
} catch {
    Write-Host "Role assignment already exists" -ForegroundColor Yellow
}

# Assign Key Vault Secrets User role to managed identity
Write-Host "Assigning Key Vault Secrets User role to managed identity..." -ForegroundColor Cyan
try {
    az role assignment create --role "Key Vault Secrets User" --assignee $MANAGED_IDENTITY_PRINCIPAL_ID --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.KeyVault/vaults/$KV_NAME" --output none 2>$null
} catch {
    Write-Host "Role assignment already exists" -ForegroundColor Yellow
}

# Wait for RBAC propagation
Write-Host "Waiting for RBAC propagation..." -ForegroundColor Cyan
Start-Sleep 30

# Create PostgreSQL Flexible Server
Write-Host "Creating PostgreSQL Flexible Server..." -ForegroundColor Cyan
try {
    az postgres flexible-server show --name $POSTGRES_NAME --resource-group $RG_NAME --output none 2>$null
    Write-Host "PostgreSQL server $POSTGRES_NAME already exists" -ForegroundColor Yellow
} catch {
    # Generate a strong password
    $DB_PASSWORD = -join ((33..126) | Get-Random -Count 25 | ForEach-Object {[char]$_})
    
    az postgres flexible-server create --name $POSTGRES_NAME --resource-group $RG_NAME --location $LOCATION --admin-user $DB_USERNAME --admin-password $DB_PASSWORD --sku-name Standard_D2ds_v5 --tier GeneralPurpose --version 17 --storage-size 32 --microsoft-entra-auth Enabled
    
    Write-Host "PostgreSQL server $POSTGRES_NAME created" -ForegroundColor Green
    
    # Store database credentials in Key Vault
    $CONNECTION_STRING = "Host=${POSTGRES_NAME}.postgres.database.azure.com;Database=${DB_NAME};Username=${DB_USERNAME};Password=${DB_PASSWORD};SslMode=Require"
    az keyvault secret set --vault-name $KV_NAME --name "postgres-connection-string" --value $CONNECTION_STRING
    az keyvault secret set --vault-name $KV_NAME --name "postgres-password" --value $DB_PASSWORD
    
    Write-Host "Database credentials stored in Key Vault" -ForegroundColor Green
}

# Create database
Write-Host "Creating database..." -ForegroundColor Cyan
try {
    az postgres flexible-server db show --resource-group $RG_NAME --server-name $POSTGRES_NAME --database-name $DB_NAME --output none 2>$null
    Write-Host "Database $DB_NAME already exists" -ForegroundColor Yellow
} catch {
    az postgres flexible-server db create --resource-group $RG_NAME --server-name $POSTGRES_NAME --database-name $DB_NAME
    Write-Host "Database $DB_NAME created" -ForegroundColor Green
}

# Add firewall rule for Azure services
Write-Host "Adding firewall rule for Azure services..." -ForegroundColor Cyan
try {
    az postgres flexible-server firewall-rule create --resource-group $RG_NAME --name $POSTGRES_NAME --rule-name "AllowAzureServices" --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --output none 2>$null
} catch {
    Write-Host "Firewall rule already exists" -ForegroundColor Yellow
}

# Create Service Bus Namespace
Write-Host "Creating Service Bus Namespace..." -ForegroundColor Cyan
try {
    az servicebus namespace show --name $SERVICEBUS_NAME --resource-group $RG_NAME --output none 2>$null
    Write-Host "Service Bus $SERVICEBUS_NAME already exists" -ForegroundColor Yellow
} catch {
    az servicebus namespace create --name $SERVICEBUS_NAME --resource-group $RG_NAME --location $LOCATION --sku Standard
    Write-Host "Service Bus $SERVICEBUS_NAME created" -ForegroundColor Green
}

# Create Service Bus Queue
Write-Host "Creating Service Bus Queue..." -ForegroundColor Cyan
try {
    az servicebus queue show --resource-group $RG_NAME --namespace-name $SERVICEBUS_NAME --name "asset-processing" --output none 2>$null
    Write-Host "Service Bus queue already exists" -ForegroundColor Yellow
} catch {
    az servicebus queue create --resource-group $RG_NAME --namespace-name $SERVICEBUS_NAME --name "asset-processing"
    Write-Host "Service Bus queue created" -ForegroundColor Green
}

# Create Storage Account
Write-Host "Creating Storage Account..." -ForegroundColor Cyan
try {
    az storage account show --name $STORAGE_NAME --resource-group $RG_NAME --output none 2>$null
    Write-Host "Storage Account $STORAGE_NAME already exists" -ForegroundColor Yellow
} catch {
    az storage account create --name $STORAGE_NAME --resource-group $RG_NAME --location $LOCATION --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false --allow-shared-key-access false
    Write-Host "Storage Account $STORAGE_NAME created" -ForegroundColor Green
}

# Create blob container
Write-Host "Creating blob container..." -ForegroundColor Cyan
try {
    az storage container show --name "assets" --account-name $STORAGE_NAME --auth-mode login --output none 2>$null
    Write-Host "Blob container already exists" -ForegroundColor Yellow
} catch {
    az storage container create --name "assets" --account-name $STORAGE_NAME --auth-mode login
    Write-Host "Blob container created" -ForegroundColor Green
}

# Get available AKS versions
$AKS_VERSION = (az aks get-versions --location $LOCATION --query "values[?isPreview==null] | [-1].version" -o tsv)
Write-Host "Using AKS version: $AKS_VERSION" -ForegroundColor Yellow

# Create AKS cluster
Write-Host "Creating AKS cluster..." -ForegroundColor Cyan
try {
    az aks show --name $AKS_NAME --resource-group $RG_NAME --output none 2>$null
    Write-Host "AKS cluster $AKS_NAME already exists" -ForegroundColor Yellow
} catch {
    az aks create --resource-group $RG_NAME --name $AKS_NAME --location $LOCATION --kubernetes-version $AKS_VERSION --node-count 2 --node-vm-size Standard_D2s_v3 --assign-identity $MANAGED_IDENTITY_ID --enable-oidc-issuer --enable-workload-identity --attach-acr $ACR_NAME --enable-addons monitoring --workspace-resource-id "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.OperationalInsights/workspaces/$LOG_WORKSPACE_NAME"
    Write-Host "AKS cluster $AKS_NAME created" -ForegroundColor Green
}

# Get AKS credentials
Write-Host "Getting AKS credentials..." -ForegroundColor Cyan
az aks get-credentials --resource-group $RG_NAME --name $AKS_NAME --overwrite-existing

# Assign AcrPull role to managed identity
Write-Host "Assigning AcrPull role to managed identity..." -ForegroundColor Cyan
$ACR_ID = (az acr show --name $ACR_NAME --resource-group $RG_NAME --query id -o tsv)
try {
    az role assignment create --role "AcrPull" --assignee $MANAGED_IDENTITY_PRINCIPAL_ID --scope $ACR_ID --output none 2>$null
} catch {
    Write-Host "Role assignment already exists" -ForegroundColor Yellow
}

# Assign Storage Blob Data Contributor role to managed identity
Write-Host "Assigning Storage Blob Data Contributor role to managed identity..." -ForegroundColor Cyan
$STORAGE_ID = (az storage account show --name $STORAGE_NAME --resource-group $RG_NAME --query id -o tsv)
try {
    az role assignment create --role "Storage Blob Data Contributor" --assignee $MANAGED_IDENTITY_PRINCIPAL_ID --scope $STORAGE_ID --output none 2>$null
} catch {
    Write-Host "Role assignment already exists" -ForegroundColor Yellow
}

# Assign Service Bus Data Owner role to managed identity
Write-Host "Assigning Service Bus Data Owner role to managed identity..." -ForegroundColor Cyan
$SERVICEBUS_ID = (az servicebus namespace show --name $SERVICEBUS_NAME --resource-group $RG_NAME --query id -o tsv)
try {
    az role assignment create --role "Azure Service Bus Data Owner" --assignee $MANAGED_IDENTITY_PRINCIPAL_ID --scope $SERVICEBUS_ID --output none 2>$null
} catch {
    Write-Host "Role assignment already exists" -ForegroundColor Yellow
}

# Store configuration in Key Vault
Write-Host "Storing configuration in Key Vault..." -ForegroundColor Cyan
az keyvault secret set --vault-name $KV_NAME --name "storage-account-name" --value $STORAGE_NAME --output none
az keyvault secret set --vault-name $KV_NAME --name "storage-container-name" --value "assets" --output none
az keyvault secret set --vault-name $KV_NAME --name "servicebus-namespace" --value $SERVICEBUS_NAME --output none
az keyvault secret set --vault-name $KV_NAME --name "managed-identity-client-id" --value $MANAGED_IDENTITY_CLIENT_ID --output none

Write-Host ""
Write-Host "🎉 Azure resources provisioned successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "=== Resource Information ===" -ForegroundColor Magenta
Write-Host "Resource Group: $RG_NAME" -ForegroundColor White
Write-Host "AKS Cluster: $AKS_NAME" -ForegroundColor White
Write-Host "Container Registry: $ACR_NAME.azurecr.io" -ForegroundColor White
Write-Host "PostgreSQL Server: $POSTGRES_NAME.postgres.database.azure.com" -ForegroundColor White
Write-Host "Database: $DB_NAME" -ForegroundColor White
Write-Host "Service Bus: $SERVICEBUS_NAME" -ForegroundColor White
Write-Host "Storage Account: $STORAGE_NAME" -ForegroundColor White
Write-Host "Key Vault: $KV_NAME" -ForegroundColor White
Write-Host "Managed Identity: $MANAGED_IDENTITY_NAME" -ForegroundColor White
Write-Host "Client ID: $MANAGED_IDENTITY_CLIENT_ID" -ForegroundColor White
Write-Host ""
Write-Host "=== Next Steps ===" -ForegroundColor Magenta
Write-Host "1. Build and push Docker images to ACR" -ForegroundColor White
Write-Host "2. Create Kubernetes manifests" -ForegroundColor White
Write-Host "3. Deploy applications to AKS" -ForegroundColor White
Write-Host ""