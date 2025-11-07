#!/bin/bash

# Build script for Asset Manager Docker images
set -e

echo "Building Asset Manager Docker images..."

# Get version from pom.xml (default to latest if not found)
VERSION=${VERSION:-latest}

echo "Building web application Docker image..."
docker build -f web/Dockerfile -t asset-manager-web:${VERSION} .

echo "Building worker application Docker image..."
docker build -f worker/Dockerfile -t asset-manager-worker:${VERSION} .

echo "Docker images built successfully!"
echo "Images created:"
docker images asset-manager-*

echo ""
echo "To run the applications, you'll need to provide the following environment variables:"
echo "- AZURE_STORAGE_ACCOUNT_NAME"
echo "- AZURE_STORAGE_BLOB_CONTAINER_NAME" 
echo "- AZURE_CLIENT_ID"
echo "- AZURE_SERVICEBUS_NAMESPACE"
echo "- Database configuration (for production use)"
echo ""
echo "Example run command:"
echo "docker run -p 8080:8080 -e AZURE_STORAGE_ACCOUNT_NAME=your_account asset-manager-web:${VERSION}"