@echo off
REM Build script for Asset Manager Docker images

echo Building Asset Manager Docker images...

REM Get version from environment variable or default to latest
if "%VERSION%"=="" set VERSION=latest

echo Building web application Docker image...
docker build -f web/Dockerfile -t asset-manager-web:%VERSION% .

if %errorlevel% neq 0 (
    echo Failed to build web application Docker image
    exit /b %errorlevel%
)

echo Building worker application Docker image...
docker build -f worker/Dockerfile -t asset-manager-worker:%VERSION% .

if %errorlevel% neq 0 (
    echo Failed to build worker application Docker image
    exit /b %errorlevel%
)

echo Docker images built successfully!
echo Images created:
docker images asset-manager-*

echo.
echo To run the applications, you'll need to provide the following environment variables:
echo - AZURE_STORAGE_ACCOUNT_NAME
echo - AZURE_STORAGE_BLOB_CONTAINER_NAME
echo - AZURE_CLIENT_ID
echo - AZURE_SERVICEBUS_NAMESPACE
echo - Database configuration (for production use)
echo.
echo Example run command:
echo docker run -p 8080:8080 -e AZURE_STORAGE_ACCOUNT_NAME=your_account asset-manager-web:%VERSION%