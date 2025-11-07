# Asset Manager Deployment Script for AKS (PowerShell)
# This script builds and pushes Docker images to ACR, then deploys to AKS

$ErrorActionPreference = "Stop"

# Configuration
$RESOURCE_GROUP = "rguied"
$ACR_NAME = "acruied"
$AKS_NAME = "aksuied"
$IMAGE_TAG = "latest"

Write-Host "🚀 Starting Asset Manager Deployment to AKS..." -ForegroundColor Green

# Step 1: Build and push Docker images to ACR
Write-Host "📦 Building and pushing Docker images to ACR..." -ForegroundColor Cyan

# Login to ACR
Write-Host "Logging into ACR..." -ForegroundColor Yellow
az acr login --name $ACR_NAME

# Build and push web application
Write-Host "Building web application Docker image..." -ForegroundColor Yellow
docker build -f web/Dockerfile -t "$ACR_NAME.azurecr.io/asset-manager-web:$IMAGE_TAG" .

Write-Host "Pushing web application image to ACR..." -ForegroundColor Yellow
docker push "$ACR_NAME.azurecr.io/asset-manager-web:$IMAGE_TAG"

# Build and push worker application
Write-Host "Building worker application Docker image..." -ForegroundColor Yellow
docker build -f worker/Dockerfile -t "$ACR_NAME.azurecr.io/asset-manager-worker:$IMAGE_TAG" .

Write-Host "Pushing worker application image to ACR..." -ForegroundColor Yellow
docker push "$ACR_NAME.azurecr.io/asset-manager-worker:$IMAGE_TAG"

# Step 2: Get AKS credentials
Write-Host "🔑 Getting AKS credentials..." -ForegroundColor Cyan
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

# Step 3: Create federated identity credential for workload identity
Write-Host "🆔 Setting up workload identity..." -ForegroundColor Cyan
$AKS_OIDC_ISSUER = (az aks show -n $AKS_NAME -g $RESOURCE_GROUP --query "oidcIssuerProfile.issuerUrl" -o tsv)

# Create federated identity credential
try {
    az identity federated-credential create --name "asset-manager-federated-identity" --identity-name "iduied" --resource-group $RESOURCE_GROUP --issuer $AKS_OIDC_ISSUER --subject "system:serviceaccount:asset-manager:asset-manager-sa" --audience "api://AzureADTokenExchange" --output none 2>$null
} catch {
    Write-Host "Federated identity credential already exists" -ForegroundColor Yellow
}

# Step 4: Deploy to AKS
Write-Host "☸️  Deploying applications to AKS..." -ForegroundColor Cyan
kubectl apply -f k8s-manifests.yaml

# Step 5: Wait for deployments to be ready
Write-Host "⏳ Waiting for deployments to be ready..." -ForegroundColor Cyan
kubectl wait --for=condition=available --timeout=300s deployment/asset-manager-web -n asset-manager
kubectl wait --for=condition=available --timeout=300s deployment/asset-manager-worker -n asset-manager

# Step 6: Get service information
Write-Host "🌐 Getting service information..." -ForegroundColor Cyan
Write-Host ""
Write-Host "=== Deployment Status ===" -ForegroundColor Magenta
kubectl get pods -n asset-manager
Write-Host ""
Write-Host "=== Services ===" -ForegroundColor Magenta
kubectl get services -n asset-manager
Write-Host ""

# Get external IP
$EXTERNAL_IP = (kubectl get service asset-manager-web-service -n asset-manager --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
if ($EXTERNAL_IP) {
    Write-Host "🎉 Application deployed successfully!" -ForegroundColor Green
    Write-Host "Web Application URL: http://$EXTERNAL_IP" -ForegroundColor White
    Write-Host ""
    Write-Host "You can access the Asset Manager application at the above URL." -ForegroundColor White
} else {
    Write-Host "⏳ External IP is still being assigned. Run the following command to check:" -ForegroundColor Yellow
    Write-Host "kubectl get service asset-manager-web-service -n asset-manager" -ForegroundColor White
}

Write-Host ""
Write-Host "=== Additional Commands ===" -ForegroundColor Magenta
Write-Host "View logs: kubectl logs -l app=asset-manager-web -n asset-manager" -ForegroundColor White
Write-Host "View worker logs: kubectl logs -l app=asset-manager-worker -n asset-manager" -ForegroundColor White
Write-Host "Scale web app: kubectl scale deployment asset-manager-web --replicas=3 -n asset-manager" -ForegroundColor White
Write-Host ""
Write-Host "✅ Deployment script completed!" -ForegroundColor Green