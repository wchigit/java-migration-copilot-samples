# Asset Manager - Build and Deploy Script (PowerShell)
# This script builds Docker images, pushes them to ACR, and deploys to AKS

param(
    [switch]$SkipBuild = $false,
    [switch]$SkipDeploy = $false
)

$ErrorActionPreference = "Stop"

# Load environment variables
if (Test-Path ".azure\environment-variables.env") {
    Get-Content ".azure\environment-variables.env" | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
        }
    }
}

$ResourceGroupName = $env:RESOURCE_GROUP_NAME
$AksClusterName = $env:AKS_CLUSTER_NAME
$AcrName = $env:ACR_NAME
$AcrLoginServer = "$AcrName.azurecr.io"

Write-Host "Asset Manager - Build and Deploy" -ForegroundColor Green
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Yellow
Write-Host "AKS Cluster: $AksClusterName" -ForegroundColor Yellow  
Write-Host "Container Registry: $AcrLoginServer" -ForegroundColor Yellow

# Check if AKS cluster is ready
Write-Host "Checking AKS cluster status..." -ForegroundColor Cyan
$aksStatus = az aks show --resource-group $ResourceGroupName --name $AksClusterName --query "provisioningState" -o tsv 2>$null
if ($aksStatus -ne "Succeeded") {
    Write-Host "AKS cluster is not ready yet. Current status: $aksStatus" -ForegroundColor Yellow
    Write-Host "Waiting for AKS cluster to be ready..." -ForegroundColor Cyan
    
    do {
        Start-Sleep -Seconds 30
        $aksStatus = az aks show --resource-group $ResourceGroupName --name $AksClusterName --query "provisioningState" -o tsv 2>$null
        Write-Host "AKS Status: $aksStatus" -ForegroundColor Yellow
    } while ($aksStatus -ne "Succeeded" -and $aksStatus -ne $null)
}

if ($aksStatus -eq "Succeeded") {
    Write-Host "AKS cluster is ready!" -ForegroundColor Green
    
    # Get AKS credentials
    Write-Host "Getting AKS credentials..." -ForegroundColor Cyan
    az aks get-credentials --resource-group $ResourceGroupName --name $AksClusterName --overwrite-existing
} else {
    Write-Host "ERROR: AKS cluster is not available. Status: $aksStatus" -ForegroundColor Red
    exit 1
}

if (-not $SkipBuild) {
    Write-Host "`n=== BUILDING AND PUSHING DOCKER IMAGES ===" -ForegroundColor Green
    
    # Login to ACR
    Write-Host "Logging into Azure Container Registry..." -ForegroundColor Cyan
    az acr login --name $AcrName
    
    # Build and push web service image
    Write-Host "Building web service image..." -ForegroundColor Cyan
    docker build -f web/Dockerfile -t "$AcrLoginServer/asset-manager-web:latest" .
    
    Write-Host "Pushing web service image..." -ForegroundColor Cyan
    docker push "$AcrLoginServer/asset-manager-web:latest"
    
    # Build and push worker service image
    Write-Host "Building worker service image..." -ForegroundColor Cyan
    docker build -f worker/Dockerfile -t "$AcrLoginServer/asset-manager-worker:latest" .
    
    Write-Host "Pushing worker service image..." -ForegroundColor Cyan
    docker push "$AcrLoginServer/asset-manager-worker:latest"
    
    Write-Host "Docker images built and pushed successfully!" -ForegroundColor Green
}

if (-not $SkipDeploy) {
    Write-Host "`n=== DEPLOYING TO KUBERNETES ===" -ForegroundColor Green
    
    # Apply Kubernetes manifests
    Write-Host "Deploying Kubernetes manifests..." -ForegroundColor Cyan
    kubectl apply -f .azure/k8s-manifests.yaml
    
    # Wait for deployments to be ready
    Write-Host "Waiting for deployments to be ready..." -ForegroundColor Cyan
    kubectl wait --for=condition=available --timeout=300s deployment/asset-manager-web -n asset-manager
    kubectl wait --for=condition=available --timeout=300s deployment/asset-manager-worker -n asset-manager
    
    Write-Host "Deployment completed successfully!" -ForegroundColor Green
    
    # Get service information
    Write-Host "`n=== SERVICE INFORMATION ===" -ForegroundColor Green
    kubectl get services -n asset-manager
    
    # Get external IP for web service
    Write-Host "`nGetting external IP for web service..." -ForegroundColor Cyan
    $externalIP = kubectl get service asset-manager-web-service -n asset-manager -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
    
    if ($externalIP) {
        Write-Host "Asset Manager Web Application is available at: http://$externalIP" -ForegroundColor Green
    } else {
        Write-Host "External IP not yet assigned. Run the following command to check:" -ForegroundColor Yellow
        Write-Host "kubectl get service asset-manager-web-service -n asset-manager" -ForegroundColor Cyan
    }
    
    # Show pod status
    Write-Host "`n=== POD STATUS ===" -ForegroundColor Green
    kubectl get pods -n asset-manager
    
    # Show deployment logs (last 10 lines)
    Write-Host "`n=== RECENT LOGS ===" -ForegroundColor Green
    Write-Host "Web service logs:" -ForegroundColor Cyan
    kubectl logs deployment/asset-manager-web -n asset-manager --tail=10
    
    Write-Host "`nWorker service logs:" -ForegroundColor Cyan
    kubectl logs deployment/asset-manager-worker -n asset-manager --tail=10
}

Write-Host "`n=== DEPLOYMENT SUMMARY ===" -ForegroundColor Green
Write-Host "✅ Infrastructure: Provisioned in Azure" -ForegroundColor Green
Write-Host "✅ Docker Images: Built and pushed to $AcrLoginServer" -ForegroundColor Green
Write-Host "✅ Kubernetes: Deployed to AKS cluster $AksClusterName" -ForegroundColor Green
Write-Host "`nTo monitor the application:" -ForegroundColor Cyan
Write-Host "kubectl get all -n asset-manager" -ForegroundColor White
Write-Host "kubectl logs -f deployment/asset-manager-web -n asset-manager" -ForegroundColor White
Write-Host "kubectl logs -f deployment/asset-manager-worker -n asset-manager" -ForegroundColor White