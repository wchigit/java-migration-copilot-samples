#!/bin/bash

# Asset Manager Deployment Script for AKS
# This script builds and pushes Docker images to ACR, then deploys to AKS

set -e  # Exit on any error

# Configuration
RESOURCE_GROUP="rguied"
ACR_NAME="acruied"
AKS_NAME="aksuied"
IMAGE_TAG="latest"

echo "🚀 Starting Asset Manager Deployment to AKS..."

# Step 1: Build and push Docker images to ACR
echo "📦 Building and pushing Docker images to ACR..."

# Login to ACR
echo "Logging into ACR..."
az acr login --name $ACR_NAME

# Build and push web application
echo "Building web application Docker image..."
docker build -f web/Dockerfile -t $ACR_NAME.azurecr.io/asset-manager-web:$IMAGE_TAG .

echo "Pushing web application image to ACR..."
docker push $ACR_NAME.azurecr.io/asset-manager-web:$IMAGE_TAG

# Build and push worker application
echo "Building worker application Docker image..."
docker build -f worker/Dockerfile -t $ACR_NAME.azurecr.io/asset-manager-worker:$IMAGE_TAG .

echo "Pushing worker application image to ACR..."
docker push $ACR_NAME.azurecr.io/asset-manager-worker:$IMAGE_TAG

# Step 2: Get AKS credentials
echo "🔑 Getting AKS credentials..."
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

# Step 3: Create federated identity credential for workload identity
echo "🆔 Setting up workload identity..."
AKS_OIDC_ISSUER=$(az aks show -n $AKS_NAME -g $RESOURCE_GROUP --query "oidcIssuerProfile.issuerUrl" -o tsv)

# Create federated identity credential
az identity federated-credential create \
    --name "asset-manager-federated-identity" \
    --identity-name "iduied" \
    --resource-group $RESOURCE_GROUP \
    --issuer $AKS_OIDC_ISSUER \
    --subject "system:serviceaccount:asset-manager:asset-manager-sa" \
    --audience "api://AzureADTokenExchange" \
    --output none 2>/dev/null || echo "Federated identity credential already exists"

# Step 4: Deploy to AKS
echo "☸️  Deploying applications to AKS..."
kubectl apply -f k8s-manifests.yaml

# Step 5: Wait for deployments to be ready
echo "⏳ Waiting for deployments to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/asset-manager-web -n asset-manager
kubectl wait --for=condition=available --timeout=300s deployment/asset-manager-worker -n asset-manager

# Step 6: Get service information
echo "🌐 Getting service information..."
echo ""
echo "=== Deployment Status ==="
kubectl get pods -n asset-manager
echo ""
echo "=== Services ==="
kubectl get services -n asset-manager
echo ""

# Get external IP
EXTERNAL_IP=$(kubectl get service asset-manager-web-service -n asset-manager --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -n "$EXTERNAL_IP" ]; then
    echo "🎉 Application deployed successfully!"
    echo "Web Application URL: http://$EXTERNAL_IP"
    echo ""
    echo "You can access the Asset Manager application at the above URL."
else
    echo "⏳ External IP is still being assigned. Run the following command to check:"
    echo "kubectl get service asset-manager-web-service -n asset-manager"
fi

echo ""
echo "=== Additional Commands ==="
echo "View logs: kubectl logs -l app=asset-manager-web -n asset-manager"
echo "View worker logs: kubectl logs -l app=asset-manager-worker -n asset-manager"
echo "Scale web app: kubectl scale deployment asset-manager-web --replicas=3 -n asset-manager"
echo ""
echo "✅ Deployment script completed!"