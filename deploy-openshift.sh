#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Configuration Variables ---
HELM_CHART_DIR="my-request-app-chart" # The directory containing your Helm chart
HELM_RELEASE_NAME="my-request-app"   # The name for your Helm release (e.g., how it appears in 'helm list')
OCP_PROJECT="my-request-app"         # The OpenShift project (namespace) where you are deploying

echo "--- Starting OpenShift Deployment Script ---"

# --- Pre-checks ---
echo "Checking for required CLIs (oc, helm, kubectl)..."
if ! command -v oc &> /dev/null; then
    echo "Error: 'oc' CLI not found. Please install OpenShift CLI."
    exit 1
fi
if ! command -v helm &> /dev/null; then
    echo "Error: 'helm' CLI not found. Please install Helm."
    exit 1
fi
if ! command -v kubectl &> /dev/null; then
    echo "Error: 'kubectl' CLI not found. Please install kubectl."
    exit 1
fi
echo "CLIs found."

echo "Ensuring you are logged into OpenShift and in the correct project..."
CURRENT_OCP_PROJECT=$(oc project -q)
if [ "${CURRENT_OCP_PROJECT}" != "${OCP_PROJECT}" ]; then
    echo "Warning: Current OpenShift project is '${CURRENT_OCP_PROJECT}'. Attempting to switch to '${OCP_PROJECT}'."
    oc project "${OCP_PROJECT}" || { echo "Error: Failed to switch to project ${OCP_PROJECT}. Ensure the project exists and you have permissions. Exiting."; exit 1; }
else
    echo "Already in the correct OpenShift project: ${OCP_PROJECT}"
fi
echo "OpenShift context set."

# --- Deploy Helm Chart ---
echo "--- Deploying Helm Chart ---"
echo "Navigating to chart directory: ${HELM_CHART_DIR}"
# Ensure the script is run from the parent directory of HELM_CHART_DIR
cd "${HELM_CHART_DIR}" || { echo "Error: Chart directory '${HELM_CHART_DIR}' not found. Please ensure the script is run from the parent directory of '${HELM_CHART_DIR}'. Exiting."; exit 1; }

# --- Clean up previous deployment if it exists ---
echo "--- Checking for existing Helm release '${HELM_RELEASE_NAME}' in project '${OCP_PROJECT}' ---"
# Check if the Helm release exists in the target namespace
if helm list -n "${OCP_PROJECT}" --short | grep -q "^${HELM_RELEASE_NAME}$"; then
    echo "Existing release '${HELM_RELEASE_NAME}' found. Uninstalling it for a clean deployment..."
    # Uninstall the existing release. --timeout 5m ensures it doesn't hang if there's a problem.
    helm uninstall "${HELM_RELEASE_NAME}" -n "${OCP_PROJECT}" --timeout 5m || {
        echo "Error: Failed to uninstall existing Helm release '${HELM_RELEASE_NAME}'. Please check its status with 'helm status ${HELM_RELEASE_NAME} -n ${OCP_PROJECT}' and try manual cleanup if necessary. Exiting."
        exit 1
    }
    echo "Existing release uninstalled successfully."
else
    echo "No existing release '${HELM_RELEASE_NAME}' found. Proceeding with a fresh installation."
fi

# --- End of clean up block ---


# Install or upgrade the Helm chart
# --atomic: if install/upgrade fails, rollback to the previous state.
# --wait: wait until all resources are in a ready state.
# --timeout: maximum time to wait for the Helm operation.
echo "Installing/Upgrading Helm chart '${HELM_RELEASE_NAME}' in project '${OCP_PROJECT}'..."
helm upgrade --install "${HELM_RELEASE_NAME}" . -n "${OCP_PROJECT}" || { echo "Error: Helm chart installation failed. Check 'helm list -n ${OCP_PROJECT}' for status. Exiting."; exit 1; }

echo "--- Helm Chart Deployed. Now triggering OpenShift Builds ---"

# --- Dynamically Get BuildConfig Names ---
# OpenShift BuildConfigs names are typically: <helm-release-name>-<chart-name>-<component>-build
# This is derived from {{ include "my-request-app-chart.fullname" . }}-<component>-build
# where fullname combines release name and chart name.
FULL_CHART_NAME="my-request-app-chart" # As defined in Chart.yaml

FRONTEND_BC_NAME="${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-frontend-build"
BACKEND_BC_NAME="${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-backend-build"

echo "Attempting to find BuildConfigs:"
echo "  Frontend expected: ${FRONTEND_BC_NAME}"
echo "  Backend expected:  ${BACKEND_BC_NAME}"

# Verify BuildConfigs actually exist before trying to start them
if ! oc get bc "${FRONTEND_BC_NAME}" -n "${OCP_PROJECT}" &> /dev/null; then
    echo "Error: Frontend BuildConfig '${FRONTEND_BC_NAME}' not found after Helm deployment. Check 'oc get bc -n ${OCP_PROJECT}'."
    exit 1
fi
if ! oc get bc "${BACKEND_BC_NAME}" -n "${OCP_PROJECT}" &> /dev/null; then
    echo "Error: Backend BuildConfig '${BACKEND_BC_NAME}' not found after Helm deployment. Check 'oc get bc -n ${OCP_PROJECT}'."
    exit 1
fi

echo "Found Frontend BuildConfig: ${FRONTEND_BC_NAME}"
echo "Found Backend BuildConfig: ${BACKEND_BC_NAME}"

# --- Trigger and Follow Builds ---
echo "--- Triggering and following builds... This may take a few minutes. ---"

# Trigger and follow the frontend build
echo "Triggering frontend build (${FRONTEND_BC_NAME})..."
oc start-build "${FRONTEND_BC_NAME}" -n "${OCP_PROJECT}" --follow || { echo "Error: Frontend build failed. Check 'oc logs -f bc/${FRONTEND_BC_NAME}'. Exiting."; exit 1; }
echo "Frontend build completed."

# Trigger and follow the backend build
echo "Triggering backend build (${BACKEND_BC_NAME})..."
oc start-build "${BACKEND_BC_NAME}" -n "${OCP_PROJECT}" --follow || { echo "Error: Backend build failed. Check 'oc logs -f bc/${BACKEND_BC_NAME}'. Exiting."; exit 1; }
echo "Backend build completed."

echo "--- Builds completed. Waiting for deployments to rollout (if new images were built) ---"
# Wait for the deployments to become ready after new images are available.
# This ensures that your pods are running the newly built images.
kubectl rollout status deployment/${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-frontend -n "${OCP_PROJECT}" --timeout=5m || { echo "Error: Frontend deployment failed to rollout within timeout. Check 'oc get pods -n ${OCP_PROJECT}'. Exiting."; exit 1; }
kubectl rollout status deployment/${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-backend -n "${OCP_PROJECT}" --timeout=5m || { echo "Error: Backend deployment failed to rollout within timeout. Check 'oc get pods -n ${OCP_PROJECT}'. Exiting."; exit 1; }

echo "--- Deployment and Builds Complete! ---"
echo "Your application should now be running."

echo ""
echo "--- Access Information ---"
# Fetch service ports dynamically for more robust output
FRONTEND_SERVICE_PORT=$(kubectl get service "${HELM_RELEASE_NAME}-frontend-service" -n "${OCP_PROJECT}" -o jsonpath='{.spec.ports[?(@.name=="http")].port}' || echo "N/A")
BACKEND_SERVICE_PORT=$(kubectl get service "${HELM_RELEASE_NAME}-backend-service" -n "${OCP_PROJECT}" -o jsonpath='{.spec.ports[?(@.name=="http")].port}' || echo "N/A")


FRONTEND_SERVICE_NAME="${HELM_RELEASE_NAME}-frontend-service"
FRONTEND_SERVICE_TYPE=$(kubectl get services "${FRONTEND_SERVICE_NAME}" -n "${OCP_PROJECT}" -o jsonpath='{.spec.type}' || echo "Unknown")

if [ "${FRONTEND_SERVICE_TYPE}" = "NodePort" ]; then
   NODE_PORT=$(kubectl get services "${FRONTEND_SERVICE_NAME}" -n "${OCP_PROJECT}" -o jsonpath='{.spec.ports[0].nodePort}' || echo "N/A")
   NODE_IP=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | head -n 1 || echo "N/A")
   echo "Frontend URL (NodePort): http://${NODE_IP}:${NODE_PORT}"
elif [ "${FRONTEND_SERVICE_TYPE}" = "LoadBalancer" ]; then
   echo "Frontend service is a LoadBalancer. It may take a few moments for the external IP to be provisioned."
   echo "Check its status with: kubectl get services ${FRONTEND_SERVICE_NAME} -n ${OCP_PROJECT} -w"
   echo "Once an external IP is available, access it at: http://<EXTERNAL-IP>:${FRONTEND_SERVICE_PORT}"
   echo "If on Minikube/Kind, you might need to use specific commands (e.g., 'minikube service ${FRONTEND_SERVICE_NAME}') or port-forward."
else
    echo "Frontend Service Type: ${FRONTEND_SERVICE_TYPE}. Access method depends on your cluster configuration."
fi

echo "Backend internal URL (used by frontend): http://${HELM_RELEASE_NAME}-backend-service:${BACKEND_SERVICE_PORT}/get-count"
echo ""
echo "To view build logs: 'oc logs -f bc/${FRONTEND_BC_NAME}' or 'oc logs -f bc/${BACKEND_BC_NAME}'"
echo "To view app logs: 'oc logs -f deployment/${HELM_RELEASE_NAME}-frontend' or 'oc logs -f deployment/${HELM_RELEASE_NAME}-backend'"
echo ""
echo "Script finished."
