#!/bin/bash

# Define container names, image tags, and network name
FRONTEND_IMAGE="my-frontend-app"
FRONTEND_CONTAINER_NAME="frontend-container"
BACKEND_IMAGE="my-backend-app"
BACKEND_CONTAINER_NAME="backend-container"
DOCKER_NETWORK="my-app-network"

echo "--- Stopping and removing existing containers (if running) ---"

# Stop and remove frontend container if it exists
if podman ps -a --format '{{.Names}}' | grep -q "${FRONTEND_CONTAINER_NAME}"; then
    echo "Stopping and removing ${FRONTEND_CONTAINER_NAME}..."
    podman stop "${FRONTEND_CONTAINER_NAME}" > /dev/null 2>&1
    podman rm "${FRONTEND_CONTAINER_NAME}" > /dev/null 2>&1
else
    echo "${FRONTEND_CONTAINER_NAME} not found or not running."
fi

# Stop and remove backend container if it exists
if podman ps -a --format '{{.Names}}' | grep -q "${BACKEND_CONTAINER_NAME}"; then
    echo "Stopping and removing ${BACKEND_CONTAINER_NAME}..."
    podman stop "${BACKEND_CONTAINER_NAME}" > /dev/null 2>&1
    podman rm "${BACKEND_CONTAINER_NAME}" > /dev/null 2>&1
else
    echo "${BACKEND_CONTAINER_NAME} not found or not running."
fi

# Remove the custom network if it exists, for a clean slate
if podman network ls --format '{{.Name}}' | grep -q "${DOCKER_NETWORK}"; then
    echo "Removing existing Docker network: ${DOCKER_NETWORK}..."
    podman network rm "${DOCKER_NETWORK}" > /dev/null 2>&1
else
    echo "Docker network ${DOCKER_NETWORK} does not exist."
fi

echo ""
echo "--- Building Docker images ---"

# Build backend image
echo "Building ${BACKEND_IMAGE} from Dockerfile.backend..."
podman build -f Dockerfile.backend -t "${BACKEND_IMAGE}" .
if [ $? -ne 0 ]; then
    echo "ERROR: Backend image build failed!"
    exit 1
fi

# Build frontend image
echo "Building ${FRONTEND_IMAGE} from Dockerfile.frontend..."
podman build -f Dockerfile.frontend -t "${FRONTEND_IMAGE}" .
if [ $? -ne 0 ]; then
    echo "ERROR: Frontend image build failed!"
    exit 1
fi

echo ""
echo "--- Creating Docker network ---"
# Create a custom network for containers to communicate
podman network create "${DOCKER_NETWORK}"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create network ${DOCKER_NETWORK}!"
    exit 1
fi

echo ""
echo "--- Starting containers ---"

# Start backend container
echo "Starting ${BACKEND_CONTAINER_NAME}..."
podman run -d -p 3000:3000 --name "${BACKEND_CONTAINER_NAME}" --network "${DOCKER_NETWORK}" "${BACKEND_IMAGE}"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to start backend container!"
    exit 1
fi

# Start frontend container
echo "Starting ${FRONTEND_CONTAINER_NAME}..."
podman run -d -p 8080:80 --name "${FRONTEND_CONTAINER_NAME}" --network "${DOCKER_NETWORK}" "${FRONTEND_IMAGE}"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to start frontend container!"
    exit 1
fi

echo ""
echo "--- Deployment Complete! ---"
echo "You can now access your application:"
echo "Frontend (displays count):   http://localhost:8080"
echo "Backend (raw JSON count):    http://localhost:3000/get-count"
echo ""
echo "Remember: Your index.html should use 'http://backend-container:3000/get-count' for the BACKEND_URL."
echo "Check container logs with: podman logs ${FRONTEND_CONTAINER_NAME} or podman logs ${BACKEND_CONTAINER_NAME}"
echo "List running containers with: podman ps"
