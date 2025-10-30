#!/bin/bash

# Asset Manager - Azure Infrastructure Provisioning Script
# This script provisions all Azure resources needed for the Asset Manager application
# Target Region: northeurope

set -e  # Exit on any error

# Configuration Variables
RESOURCE_TOKEN="$(openssl rand -hex 2 | cut -c1-5)"
LOCATION="northeurope"
SUBSCRIPTION_ID="a4ab3025-1b32-4394-92e0-d07c1ebf3787"

# Resource Names (following naming convention: {prefix}{token}{instance})
RESOURCE_GROUP_NAME="rg${RESOURCE_TOKEN}"
AKS_CLUSTER_NAME="aks${RESOURCE_TOKEN}"
ACR_NAME="acr${RESOURCE_TOKEN}"
POSTGRES_SERVER_NAME="pg${RESOURCE_TOKEN}"
STORAGE_ACCOUNT_NAME="st${RESOURCE_TOKEN}"
SERVICE_BUS_NAME="sb${RESOURCE_TOKEN}"
KEY_VAULT_NAME="kv${RESOURCE_TOKEN}"
APP_INSIGHTS_NAME="ai${RESOURCE_TOKEN}"
LOG_ANALYTICS_NAME="la${RESOURCE_TOKEN}"
MANAGED_IDENTITY_NAME="id${RESOURCE_TOKEN}"

# Database Configuration
POSTGRES_ADMIN_USERNAME="assetadmin"
POSTGRES_DATABASE_NAME="assets_manager"
SERVICE_BUS_QUEUE_NAME="image-processing"
STORAGE_CONTAINER_NAME="images"

echo "Starting Azure Infrastructure Provisioning for Asset Manager..."
echo "Resource Token: ${RESOURCE_TOKEN}"
echo "Target Location: ${LOCATION}"
echo "Subscription: ${SUBSCRIPTION_ID}"

# Set the subscription
echo "Setting Azure subscription..."
az account set --subscription "${SUBSCRIPTION_ID}"

# Create Resource Group
echo "Creating Resource Group: ${RESOURCE_GROUP_NAME}..."
az group create \
  --name "${RESOURCE_GROUP_NAME}" \
  --location "${LOCATION}" \
  --tags "project=asset-manager" "environment=production"

# Create User-Assigned Managed Identity
echo "Creating User-Assigned Managed Identity: ${MANAGED_IDENTITY_NAME}..."
az identity create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${MANAGED_IDENTITY_NAME}" \
  --location "${LOCATION}"

# Get Managed Identity details
IDENTITY_ID=$(az identity show --resource-group "${RESOURCE_GROUP_NAME}" --name "${MANAGED_IDENTITY_NAME}" --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --resource-group "${RESOURCE_GROUP_NAME}" --name "${MANAGED_IDENTITY_NAME}" --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group "${RESOURCE_GROUP_NAME}" --name "${MANAGED_IDENTITY_NAME}" --query principalId -o tsv)

echo "Identity ID: ${IDENTITY_ID}"
echo "Identity Client ID: ${IDENTITY_CLIENT_ID}"
echo "Identity Principal ID: ${IDENTITY_PRINCIPAL_ID}"

# Create Log Analytics Workspace
echo "Creating Log Analytics Workspace: ${LOG_ANALYTICS_NAME}..."
az monitor log-analytics workspace create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --workspace-name "${LOG_ANALYTICS_NAME}" \
  --location "${LOCATION}" \
  --sku "PerGB2018"

# Get Log Analytics Workspace ID
LOG_ANALYTICS_ID=$(az monitor log-analytics workspace show --resource-group "${RESOURCE_GROUP_NAME}" --workspace-name "${LOG_ANALYTICS_NAME}" --query id -o tsv)

# Create Application Insights
echo "Creating Application Insights: ${APP_INSIGHTS_NAME}..."
az monitor app-insights component create \
  --app "${APP_INSIGHTS_NAME}" \
  --location "${LOCATION}" \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --workspace "${LOG_ANALYTICS_ID}"

# Create Azure Container Registry
echo "Creating Azure Container Registry: ${ACR_NAME}..."
az acr create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${ACR_NAME}" \
  --sku "Basic" \
  --location "${LOCATION}" \
  --admin-enabled false

# Assign AcrPull role to Managed Identity
echo "Assigning AcrPull role to Managed Identity..."
ACR_RESOURCE_ID=$(az acr show --resource-group "${RESOURCE_GROUP_NAME}" --name "${ACR_NAME}" --query id -o tsv)
az role assignment create \
  --assignee "${IDENTITY_PRINCIPAL_ID}" \
  --role "7f951dda-4ed3-4680-a7ca-43fe172d538d" \
  --scope "${ACR_RESOURCE_ID}"

# Create Azure Kubernetes Service
echo "Creating AKS Cluster: ${AKS_CLUSTER_NAME}..."
az aks create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${AKS_CLUSTER_NAME}" \
  --location "${LOCATION}" \
  --node-count 2 \
  --node-vm-size "Standard_B2ms" \
  --enable-managed-identity \
  --assign-identity "${IDENTITY_ID}" \
  --attach-acr "${ACR_NAME}" \
  --enable-addons monitoring \
  --workspace-resource-id "${LOG_ANALYTICS_ID}" \
  --kubernetes-version "1.28"

# Create Storage Account
echo "Creating Storage Account: ${STORAGE_ACCOUNT_NAME}..."
az storage account create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${STORAGE_ACCOUNT_NAME}" \
  --location "${LOCATION}" \
  --sku "Standard_LRS" \
  --kind "StorageV2" \
  --access-tier "Hot"

# Create blob container
echo "Creating blob container: ${STORAGE_CONTAINER_NAME}..."
az storage container create \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --name "${STORAGE_CONTAINER_NAME}" \
  --auth-mode login

# Assign Storage Blob Data Contributor role to Managed Identity
echo "Assigning Storage Blob Data Contributor role to Managed Identity..."
STORAGE_RESOURCE_ID=$(az storage account show --resource-group "${RESOURCE_GROUP_NAME}" --name "${STORAGE_ACCOUNT_NAME}" --query id -o tsv)
az role assignment create \
  --assignee "${IDENTITY_PRINCIPAL_ID}" \
  --role "ba92f5b4-2d11-453d-a403-e96b0029c9fe" \
  --scope "${STORAGE_RESOURCE_ID}"

# Create PostgreSQL Flexible Server
echo "Creating PostgreSQL Flexible Server: ${POSTGRES_SERVER_NAME}..."
az postgres flexible-server create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${POSTGRES_SERVER_NAME}" \
  --location "${LOCATION}" \
  --admin-user "${POSTGRES_ADMIN_USERNAME}" \
  --admin-password "P@ssw0rd123!" \
  --sku-name "Standard_B1ms" \
  --tier "Burstable" \
  --storage-size 32 \
  --version 15 \
  --public-access "All"

# Create database
echo "Creating database: ${POSTGRES_DATABASE_NAME}..."
az postgres flexible-server db create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --server-name "${POSTGRES_SERVER_NAME}" \
  --database-name "${POSTGRES_DATABASE_NAME}"

# Create Service Bus Namespace
echo "Creating Service Bus Namespace: ${SERVICE_BUS_NAME}..."
az servicebus namespace create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${SERVICE_BUS_NAME}" \
  --location "${LOCATION}" \
  --sku "Standard"

# Create Service Bus Queue
echo "Creating Service Bus Queue: ${SERVICE_BUS_QUEUE_NAME}..."
az servicebus queue create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --namespace-name "${SERVICE_BUS_NAME}" \
  --name "${SERVICE_BUS_QUEUE_NAME}" \
  --max-size 1024

# Assign Service Bus Data Owner role to Managed Identity
echo "Assigning Service Bus Data Owner role to Managed Identity..."
SERVICE_BUS_RESOURCE_ID=$(az servicebus namespace show --resource-group "${RESOURCE_GROUP_NAME}" --name "${SERVICE_BUS_NAME}" --query id -o tsv)
az role assignment create \
  --assignee "${IDENTITY_PRINCIPAL_ID}" \
  --role "090c5cfd-751d-490a-894a-3ce6f1109419" \
  --scope "${SERVICE_BUS_RESOURCE_ID}"

# Create Key Vault
echo "Creating Key Vault: ${KEY_VAULT_NAME}..."
az keyvault create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${KEY_VAULT_NAME}" \
  --location "${LOCATION}" \
  --sku "standard" \
  --enable-rbac-authorization true

# Assign Key Vault Secrets User role to Managed Identity
echo "Assigning Key Vault Secrets User role to Managed Identity..."
KEY_VAULT_RESOURCE_ID=$(az keyvault show --resource-group "${RESOURCE_GROUP_NAME}" --name "${KEY_VAULT_NAME}" --query id -o tsv)
az role assignment create \
  --assignee "${IDENTITY_PRINCIPAL_ID}" \
  --role "4633458b-17de-408a-b874-0445c86b69e6" \
  --scope "${KEY_VAULT_RESOURCE_ID}"

# Store connection strings in Key Vault
echo "Storing connection strings in Key Vault..."
POSTGRES_CONNECTION_STRING="Host=${POSTGRES_SERVER_NAME}.postgres.database.azure.com;Database=${POSTGRES_DATABASE_NAME};Username=${POSTGRES_ADMIN_USERNAME};Password=P@ssw0rd123!;Port=5432;SSL Mode=Require;"

az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "postgres-connection-string" \
  --value "${POSTGRES_CONNECTION_STRING}"

# Get AKS credentials
echo "Getting AKS credentials..."
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${AKS_CLUSTER_NAME}" \
  --overwrite-existing

# Output summary
echo ""
echo "=========================================="
echo "Azure Infrastructure Provisioning Complete!"
echo "=========================================="
echo "Resource Group: ${RESOURCE_GROUP_NAME}"
echo "AKS Cluster: ${AKS_CLUSTER_NAME}"
echo "Container Registry: ${ACR_NAME}"
echo "PostgreSQL Server: ${POSTGRES_SERVER_NAME}"
echo "Storage Account: ${STORAGE_ACCOUNT_NAME}"
echo "Service Bus: ${SERVICE_BUS_NAME}"
echo "Key Vault: ${KEY_VAULT_NAME}"
echo "Managed Identity: ${MANAGED_IDENTITY_NAME}"
echo "Identity Client ID: ${IDENTITY_CLIENT_ID}"
echo ""
echo "Environment Variables for Applications:"
echo "AZURE_CLIENT_ID=${IDENTITY_CLIENT_ID}"
echo "AZURE_STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME}"
echo "AZURE_STORAGE_BLOB_CONTAINER_NAME=${STORAGE_CONTAINER_NAME}"
echo "AZURE_SERVICEBUS_NAMESPACE=${SERVICE_BUS_NAME}"
echo "SPRING_DATASOURCE_URL=jdbc:postgresql://${POSTGRES_SERVER_NAME}.postgres.database.azure.com:5432/${POSTGRES_DATABASE_NAME}?sslmode=require"
echo "SPRING_DATASOURCE_USERNAME=${POSTGRES_ADMIN_USERNAME}"
echo "SPRING_DATASOURCE_PASSWORD=P@ssw0rd123!"
echo ""
echo "Next Steps:"
echo "1. Build and push container images to ACR"
echo "2. Deploy Kubernetes manifests to AKS"
echo "3. Configure application environment variables"
echo "=========================================="

# Save environment variables to file
cat > ".azure/environment-variables.env" << EOF
RESOURCE_TOKEN=${RESOURCE_TOKEN}
RESOURCE_GROUP_NAME=${RESOURCE_GROUP_NAME}
AKS_CLUSTER_NAME=${AKS_CLUSTER_NAME}
ACR_NAME=${ACR_NAME}
POSTGRES_SERVER_NAME=${POSTGRES_SERVER_NAME}
STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME}
SERVICE_BUS_NAME=${SERVICE_BUS_NAME}
KEY_VAULT_NAME=${KEY_VAULT_NAME}
MANAGED_IDENTITY_NAME=${MANAGED_IDENTITY_NAME}
AZURE_CLIENT_ID=${IDENTITY_CLIENT_ID}
AZURE_STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME}
AZURE_STORAGE_BLOB_CONTAINER_NAME=${STORAGE_CONTAINER_NAME}
AZURE_SERVICEBUS_NAMESPACE=${SERVICE_BUS_NAME}
SPRING_DATASOURCE_URL=jdbc:postgresql://${POSTGRES_SERVER_NAME}.postgres.database.azure.com:5432/${POSTGRES_DATABASE_NAME}?sslmode=require
SPRING_DATASOURCE_USERNAME=${POSTGRES_ADMIN_USERNAME}
SPRING_DATASOURCE_PASSWORD=P@ssw0rd123!
EOF

echo "Environment variables saved to .azure/environment-variables.env"