#!/bin/bash

# Azure Asset Manager Deployment Script
# This script provisions all required Azure resources for the Asset Manager application on AKS

set -e  # Exit on any error

# Configuration variables
RESOURCE_GROUP_NAME="rg-asset-manager"
LOCATION="westus3"
RESOURCE_TOKEN="$(openssl rand -hex 2 | tr '[:upper:]' '[:lower:]')"  # 4 character random string
CURRENT_USER=$(az account show --query user.name -o tsv)

# Resource names using naming convention: {prefix}{token}{instance}
RG_NAME="rg${RESOURCE_TOKEN}"
AKS_NAME="aks${RESOURCE_TOKEN}"
ACR_NAME="acr${RESOURCE_TOKEN}"
KV_NAME="kv${RESOURCE_TOKEN}"
POSTGRES_NAME="psql${RESOURCE_TOKEN}"
SERVICEBUS_NAME="sb${RESOURCE_TOKEN}"
STORAGE_NAME="st${RESOURCE_TOKEN}"
LOG_WORKSPACE_NAME="log${RESOURCE_TOKEN}"
APP_INSIGHTS_NAME="ai${RESOURCE_TOKEN}"
MANAGED_IDENTITY_NAME="id${RESOURCE_TOKEN}"

# Database configuration
DB_NAME="assetdb"
DB_USERNAME="assetadmin"

echo "Starting Azure resource provisioning..."
echo "Resource Token: ${RESOURCE_TOKEN}"
echo "Location: ${LOCATION}"

# Check if resource group exists, create if not
echo "Creating resource group..."
if ! az group show --name "$RG_NAME" --output none 2>/dev/null; then
    az group create --name "$RG_NAME" --location "$LOCATION"
    echo "Resource group $RG_NAME created"
else
    echo "Resource group $RG_NAME already exists"
fi

# Create Log Analytics Workspace
echo "Creating Log Analytics Workspace..."
if ! az monitor log-analytics workspace show --resource-group "$RG_NAME" --workspace-name "$LOG_WORKSPACE_NAME" --output none 2>/dev/null; then
    az monitor log-analytics workspace create \
        --resource-group "$RG_NAME" \
        --workspace-name "$LOG_WORKSPACE_NAME" \
        --location "$LOCATION"
    echo "Log Analytics Workspace $LOG_WORKSPACE_NAME created"
else
    echo "Log Analytics Workspace $LOG_WORKSPACE_NAME already exists"
fi

# Create Application Insights
echo "Creating Application Insights..."
if ! az monitor app-insights component show --app "$APP_INSIGHTS_NAME" --resource-group "$RG_NAME" --output none 2>/dev/null; then
    WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RG_NAME" --workspace-name "$LOG_WORKSPACE_NAME" --query id -o tsv)
    az monitor app-insights component create \
        --app "$APP_INSIGHTS_NAME" \
        --location "$LOCATION" \
        --resource-group "$RG_NAME" \
        --workspace "$WORKSPACE_ID"
    echo "Application Insights $APP_INSIGHTS_NAME created"
else
    echo "Application Insights $APP_INSIGHTS_NAME already exists"
fi

# Create User-Assigned Managed Identity
echo "Creating User-Assigned Managed Identity..."
if ! az identity show --resource-group "$RG_NAME" --name "$MANAGED_IDENTITY_NAME" --output none 2>/dev/null; then
    az identity create \
        --resource-group "$RG_NAME" \
        --name "$MANAGED_IDENTITY_NAME"
    echo "Managed Identity $MANAGED_IDENTITY_NAME created"
else
    echo "Managed Identity $MANAGED_IDENTITY_NAME already exists"
fi

# Get managed identity details
MANAGED_IDENTITY_ID=$(az identity show --resource-group "$RG_NAME" --name "$MANAGED_IDENTITY_NAME" --query id -o tsv)
MANAGED_IDENTITY_CLIENT_ID=$(az identity show --resource-group "$RG_NAME" --name "$MANAGED_IDENTITY_NAME" --query clientId -o tsv)
MANAGED_IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group "$RG_NAME" --name "$MANAGED_IDENTITY_NAME" --query principalId -o tsv)

# Create Container Registry
echo "Creating Azure Container Registry..."
if ! az acr show --name "$ACR_NAME" --resource-group "$RG_NAME" --output none 2>/dev/null; then
    az acr create \
        --name "$ACR_NAME" \
        --resource-group "$RG_NAME" \
        --sku Standard \
        --location "$LOCATION"
    echo "Container Registry $ACR_NAME created"
else
    echo "Container Registry $ACR_NAME already exists"
fi

# Create Key Vault with RBAC
echo "Creating Key Vault..."
if ! az keyvault show --name "$KV_NAME" --resource-group "$RG_NAME" --output none 2>/dev/null; then
    az keyvault create \
        --name "$KV_NAME" \
        --resource-group "$RG_NAME" \
        --location "$LOCATION" \
        --enable-rbac-authorization true \
        --default-action Allow \
        --bypass AzureServices
    echo "Key Vault $KV_NAME created"
else
    echo "Key Vault $KV_NAME already exists"
fi

# Assign Key Vault Secrets Officer role to current user
echo "Assigning Key Vault Secrets Officer role to current user..."
CURRENT_USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
    --role "Key Vault Secrets Officer" \
    --assignee "$CURRENT_USER_OBJECT_ID" \
    --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG_NAME/providers/Microsoft.KeyVault/vaults/$KV_NAME" \
    --output none 2>/dev/null || echo "Role assignment already exists"

# Assign Key Vault Secrets User role to managed identity
echo "Assigning Key Vault Secrets User role to managed identity..."
az role assignment create \
    --role "Key Vault Secrets User" \
    --assignee "$MANAGED_IDENTITY_PRINCIPAL_ID" \
    --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG_NAME/providers/Microsoft.KeyVault/vaults/$KV_NAME" \
    --output none 2>/dev/null || echo "Role assignment already exists"

# Wait for RBAC propagation
echo "Waiting for RBAC propagation..."
sleep 30

# Create PostgreSQL Flexible Server
echo "Creating PostgreSQL Flexible Server..."
if ! az postgres flexible-server show --name "$POSTGRES_NAME" --resource-group "$RG_NAME" --output none 2>/dev/null; then
    # Generate a strong password
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d /=+ | cut -c -25)
    
    az postgres flexible-server create \
        --name "$POSTGRES_NAME" \
        --resource-group "$RG_NAME" \
        --location "$LOCATION" \
        --admin-user "$DB_USERNAME" \
        --admin-password "$DB_PASSWORD" \
        --sku-name Standard_D2ds_v5 \
        --tier GeneralPurpose \
        --version 17 \
        --storage-size 32 \
        --microsoft-entra-auth Enabled
    
    echo "PostgreSQL server $POSTGRES_NAME created"
    
    # Store database credentials in Key Vault
    CONNECTION_STRING="Host=${POSTGRES_NAME}.postgres.database.azure.com;Database=${DB_NAME};Username=${DB_USERNAME};Password=${DB_PASSWORD};SslMode=Require"
    az keyvault secret set \
        --vault-name "$KV_NAME" \
        --name "postgres-connection-string" \
        --value "$CONNECTION_STRING"
    
    az keyvault secret set \
        --vault-name "$KV_NAME" \
        --name "postgres-password" \
        --value "$DB_PASSWORD"
        
    echo "Database credentials stored in Key Vault"
else
    echo "PostgreSQL server $POSTGRES_NAME already exists"
fi

# Create database
echo "Creating database..."
if ! az postgres flexible-server db show --resource-group "$RG_NAME" --server-name "$POSTGRES_NAME" --database-name "$DB_NAME" --output none 2>/dev/null; then
    az postgres flexible-server db create \
        --resource-group "$RG_NAME" \
        --server-name "$POSTGRES_NAME" \
        --database-name "$DB_NAME"
    echo "Database $DB_NAME created"
else
    echo "Database $DB_NAME already exists"
fi

# Add firewall rule for Azure services
echo "Adding firewall rule for Azure services..."
az postgres flexible-server firewall-rule create \
    --resource-group "$RG_NAME" \
    --name "$POSTGRES_NAME" \
    --rule-name "AllowAzureServices" \
    --start-ip-address 0.0.0.0 \
    --end-ip-address 0.0.0.0 \
    --output none 2>/dev/null || echo "Firewall rule already exists"

# Create Service Bus Namespace
echo "Creating Service Bus Namespace..."
if ! az servicebus namespace show --name "$SERVICEBUS_NAME" --resource-group "$RG_NAME" --output none 2>/dev/null; then
    az servicebus namespace create \
        --name "$SERVICEBUS_NAME" \
        --resource-group "$RG_NAME" \
        --location "$LOCATION" \
        --sku Standard
    echo "Service Bus $SERVICEBUS_NAME created"
else
    echo "Service Bus $SERVICEBUS_NAME already exists"
fi

# Create Service Bus Queue
echo "Creating Service Bus Queue..."
if ! az servicebus queue show --resource-group "$RG_NAME" --namespace-name "$SERVICEBUS_NAME" --name "asset-processing" --output none 2>/dev/null; then
    az servicebus queue create \
        --resource-group "$RG_NAME" \
        --namespace-name "$SERVICEBUS_NAME" \
        --name "asset-processing"
    echo "Service Bus queue created"
else
    echo "Service Bus queue already exists"
fi

# Create Storage Account
echo "Creating Storage Account..."
if ! az storage account show --name "$STORAGE_NAME" --resource-group "$RG_NAME" --output none 2>/dev/null; then
    az storage account create \
        --name "$STORAGE_NAME" \
        --resource-group "$RG_NAME" \
        --location "$LOCATION" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --allow-blob-public-access false \
        --allow-shared-key-access false
    echo "Storage Account $STORAGE_NAME created"
else
    echo "Storage Account $STORAGE_NAME already exists"
fi

# Create blob container
echo "Creating blob container..."
if ! az storage container show --name "assets" --account-name "$STORAGE_NAME" --auth-mode login --output none 2>/dev/null; then
    az storage container create \
        --name "assets" \
        --account-name "$STORAGE_NAME" \
        --auth-mode login
    echo "Blob container created"
else
    echo "Blob container already exists"
fi

# Get available AKS versions
AKS_VERSION=$(az aks get-versions --location "$LOCATION" --query "values[?isPreview==null] | [-1].version" -o tsv)
echo "Using AKS version: $AKS_VERSION"

# Create AKS cluster
echo "Creating AKS cluster..."
if ! az aks show --name "$AKS_NAME" --resource-group "$RG_NAME" --output none 2>/dev/null; then
    az aks create \
        --resource-group "$RG_NAME" \
        --name "$AKS_NAME" \
        --location "$LOCATION" \
        --kubernetes-version "$AKS_VERSION" \
        --node-count 2 \
        --node-vm-size Standard_D2s_v3 \
        --assign-identity "$MANAGED_IDENTITY_ID" \
        --enable-oidc-issuer \
        --enable-workload-identity \
        --attach-acr "$ACR_NAME" \
        --enable-addons monitoring \
        --workspace-resource-id "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG_NAME/providers/Microsoft.OperationalInsights/workspaces/$LOG_WORKSPACE_NAME"
    echo "AKS cluster $AKS_NAME created"
else
    echo "AKS cluster $AKS_NAME already exists"
fi

# Get AKS credentials
echo "Getting AKS credentials..."
az aks get-credentials --resource-group "$RG_NAME" --name "$AKS_NAME" --overwrite-existing

# Assign AcrPull role to managed identity
echo "Assigning AcrPull role to managed identity..."
ACR_ID=$(az acr show --name "$ACR_NAME" --resource-group "$RG_NAME" --query id -o tsv)
az role assignment create \
    --role "AcrPull" \
    --assignee "$MANAGED_IDENTITY_PRINCIPAL_ID" \
    --scope "$ACR_ID" \
    --output none 2>/dev/null || echo "Role assignment already exists"

# Assign Storage Blob Data Contributor role to managed identity
echo "Assigning Storage Blob Data Contributor role to managed identity..."
STORAGE_ID=$(az storage account show --name "$STORAGE_NAME" --resource-group "$RG_NAME" --query id -o tsv)
az role assignment create \
    --role "Storage Blob Data Contributor" \
    --assignee "$MANAGED_IDENTITY_PRINCIPAL_ID" \
    --scope "$STORAGE_ID" \
    --output none 2>/dev/null || echo "Role assignment already exists"

# Assign Service Bus Data Owner role to managed identity
echo "Assigning Service Bus Data Owner role to managed identity..."
SERVICEBUS_ID=$(az servicebus namespace show --name "$SERVICEBUS_NAME" --resource-group "$RG_NAME" --query id -o tsv)
az role assignment create \
    --role "Azure Service Bus Data Owner" \
    --assignee "$MANAGED_IDENTITY_PRINCIPAL_ID" \
    --scope "$SERVICEBUS_ID" \
    --output none 2>/dev/null || echo "Role assignment already exists"

# Store configuration in Key Vault
echo "Storing configuration in Key Vault..."
az keyvault secret set --vault-name "$KV_NAME" --name "storage-account-name" --value "$STORAGE_NAME" --output none
az keyvault secret set --vault-name "$KV_NAME" --name "storage-container-name" --value "assets" --output none
az keyvault secret set --vault-name "$KV_NAME" --name "servicebus-namespace" --value "$SERVICEBUS_NAME" --output none
az keyvault secret set --vault-name "$KV_NAME" --name "managed-identity-client-id" --value "$MANAGED_IDENTITY_CLIENT_ID" --output none

echo ""
echo "🎉 Azure resources provisioned successfully!"
echo ""
echo "=== Resource Information ==="
echo "Resource Group: $RG_NAME"
echo "AKS Cluster: $AKS_NAME"
echo "Container Registry: $ACR_NAME.azurecr.io"
echo "PostgreSQL Server: $POSTGRES_NAME.postgres.database.azure.com"
echo "Database: $DB_NAME"
echo "Service Bus: $SERVICEBUS_NAME"
echo "Storage Account: $STORAGE_NAME"
echo "Key Vault: $KV_NAME"
echo "Managed Identity: $MANAGED_IDENTITY_NAME"
echo "Client ID: $MANAGED_IDENTITY_CLIENT_ID"
echo ""
echo "=== Next Steps ==="
echo "1. Build and push Docker images to ACR"
echo "2. Create Kubernetes manifests"
echo "3. Deploy applications to AKS"
echo ""