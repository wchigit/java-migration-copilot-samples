# Asset Manager AKS Status Check Script
# This script checks the status of the deployment and provides useful monitoring commands

$ErrorActionPreference = "Stop"

# Configuration
$RESOURCE_GROUP = "rguied"
$ACR_NAME = "acruied"
$AKS_NAME = "aksuied"
$NAMESPACE = "asset-manager"

Write-Host "🔍 Asset Manager AKS Status Check" -ForegroundColor Green
Write-Host "================================" -ForegroundColor Green
Write-Host ""

# Check AKS cluster status
Write-Host "📊 AKS Cluster Status:" -ForegroundColor Cyan
try {
    $AKS_STATUS = (az aks show --resource-group $RESOURCE_GROUP --name $AKS_NAME --query "provisioningState" -o tsv)
    Write-Host "Cluster Status: $AKS_STATUS" -ForegroundColor White
    
    if ($AKS_STATUS -eq "Succeeded") {
        Write-Host "✅ AKS cluster is ready!" -ForegroundColor Green
        
        # Get credentials if not already configured
        Write-Host "Getting AKS credentials..." -ForegroundColor Yellow
        az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing
        
        # Check if namespace exists
        Write-Host ""
        Write-Host "📦 Checking deployment status:" -ForegroundColor Cyan
        $NAMESPACE_EXISTS = (kubectl get namespace $NAMESPACE --ignore-not-found=true --output name)
        
        if ($NAMESPACE_EXISTS) {
            Write-Host "Namespace '$NAMESPACE' exists" -ForegroundColor Green
            
            # Check deployments
            Write-Host ""
            Write-Host "=== Deployments ===" -ForegroundColor Magenta
            kubectl get deployments -n $NAMESPACE
            
            # Check pods
            Write-Host ""
            Write-Host "=== Pods ===" -ForegroundColor Magenta
            kubectl get pods -n $NAMESPACE
            
            # Check services
            Write-Host ""
            Write-Host "=== Services ===" -ForegroundColor Magenta
            kubectl get services -n $NAMESPACE
            
            # Check for external IP
            $EXTERNAL_IP = (kubectl get service asset-manager-web-service -n $NAMESPACE --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null)
            
            Write-Host ""
            if ($EXTERNAL_IP) {
                Write-Host "🌐 Application URL: http://$EXTERNAL_IP" -ForegroundColor Green
            } else {
                Write-Host "⏳ External IP is still being assigned..." -ForegroundColor Yellow
                Write-Host "Check again with: kubectl get service asset-manager-web-service -n $NAMESPACE" -ForegroundColor White
            }
            
        } else {
            Write-Host "❌ Namespace '$NAMESPACE' not found. Application not deployed yet." -ForegroundColor Red
            Write-Host "Run the deployment script: .\deploy-to-aks.ps1" -ForegroundColor White
        }
        
    } else {
        Write-Host "⏳ AKS cluster is still being created (Status: $AKS_STATUS)" -ForegroundColor Yellow
        Write-Host "This may take 10-15 minutes. Check again later." -ForegroundColor White
    }
    
} catch {
    Write-Host "❌ Failed to get AKS cluster status. Make sure the cluster exists." -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Useful Commands ===" -ForegroundColor Magenta
Write-Host "Check cluster status: az aks show --resource-group $RESOURCE_GROUP --name $AKS_NAME --query provisioningState" -ForegroundColor White
Write-Host "Get credentials: az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME" -ForegroundColor White
Write-Host "View pods: kubectl get pods -n $NAMESPACE" -ForegroundColor White
Write-Host "View logs: kubectl logs -l app=asset-manager-web -n $NAMESPACE" -ForegroundColor White
Write-Host "View worker logs: kubectl logs -l app=asset-manager-worker -n $NAMESPACE" -ForegroundColor White
Write-Host "Delete deployment: kubectl delete namespace $NAMESPACE" -ForegroundColor White
Write-Host ""