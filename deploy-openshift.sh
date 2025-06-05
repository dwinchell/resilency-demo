#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Configuration Variables ---
HELM_CHART_DIR="my-request-app-chart" # The directory containing your Helm chart
HELM_RELEASE_NAME="my-request-app"   # The name for your Helm release (e.g., how it appears in 'helm list')
OCP_PROJECT="my-request-app"         # The OpenShift project (namespace) where you are deploying
FULL_CHART_NAME="my-request-app-chart" # As defined in Chart.yaml

# --- Dynamic Frontend Host ---
# Check if a frontend host argument is provided
FRONTEND_HOST=""
HELM_SET_ARGS=""
if [ -n "$1" ]; then
    FRONTEND_HOST="$1"
    echo "Using provided frontend host: ${FRONTEND_HOST}"
    HELM_SET_ARGS="--set frontend.route.host=${FRONTEND_HOST}"
else
    echo "No frontend host provided as a command-line argument."
    echo "OpenShift will attempt to generate a hostname for the Route."
    echo "If the auto-generated hostname is too long, the Route creation might fail."
    echo "Usage: ./deploy-openshift.sh <frontend_host>"
    echo "Example: ./deploy-openshift.sh myfe.apps.cluster-fnpnt.fnpnt.sandbox1206.opentlc.com"
fi

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
cd "${HELM_CHART_DIR}" || { echo "Error: Chart directory '${HELM_CHART_DIR}' not found. Please ensure the script is run from the parent directory of '${HELM_CHART_DIR}'. Exiting."; exit 1; }

# --- Clean up previous deployment if it exists ---
echo "--- Checking for existing Helm release '${HELM_RELEASE_NAME}' in project '${OCP_PROJECT}' ---"
if helm list -n "${OCP_PROJECT}" --short | grep -q "^${HELM_RELEASE_NAME}$"; then
    echo "Stopping and removing existing release '${HELM_RELEASE_NAME}' for a clean deployment..."
    helm uninstall "${HELM_RELEASE_NAME}" -n "${OCP_PROJECT}" --timeout 5m || {
        echo "Error: Failed to uninstall existing Helm release '${HELM_RELEASE_NAME}'. Please check its status with 'helm status ${HELM_RELEASE_NAME} -n ${OCP_PROJECT}' and try manual cleanup if necessary. Exiting."
        exit 1
    }
    echo "Existing release uninstalled successfully."
else
    echo "No existing release '${HELM_RELEASE_NAME}' found. Proceeding with a fresh installation."
fi

echo "Installing/Upgrading Helm chart '${HELM_RELEASE_NAME}' in project '${OCP_PROJECT}'..."
# Pass the dynamic --set arguments to Helm
helm upgrade --install "${HELM_RELEASE_NAME}" . -n "${OCP_PROJECT}" ${HELM_SET_ARGS} || { echo "Error: Helm chart installation failed. Check 'helm list -n ${OCP_PROJECT}' for status. Exiting."; exit 1; }

echo "--- Helm Chart Deployed. Now triggering OpenShift Builds ---"

# --- Dynamically Get BuildConfig Names ---
FRONTEND_BC_NAME="${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-frontend-build"
BACKEND_BC_NAME="${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-backend-build"

echo "Attempting to find BuildConfigs:"
echo "  Frontend expected: ${FRONTEND_BC_NAME}"
echo "  Backend expected:  ${BACKEND_BC_NAME}"

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

echo "--- Triggering and following builds... This may take a few minutes. ---"

echo "Triggering frontend build (${FRONTEND_BC_NAME})..."
oc start-build "${FRONTEND_BC_NAME}" -n "${OCP_PROJECT}" --follow || { echo "Error: Frontend build failed. Check 'oc logs -f bc/${FRONTEND_BC_NAME}'. Exiting."; exit 1; }
echo "Frontend build completed."

echo "Triggering backend build (${BACKEND_BC_NAME})..."
oc start-build "${BACKEND_BC_NAME}" -n "${OCP_PROJECT}" --follow || { echo "Error: Backend build failed. Check 'oc logs -f bc/${BACKEND_BC_NAME}'. Exiting."; exit 1; }
echo "Backend build completed."

echo "--- Builds completed. Waiting for deployments to rollout (if new images were built) ---"
kubectl rollout status deployment/${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-frontend -n "${OCP_PROJECT}" --timeout=5m || { echo "Error: Frontend deployment failed to rollout within timeout. Check 'oc get pods -n ${OCP_PROJECT}'. Exiting."; exit 1; }
kubectl rollout status deployment/${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-backend -n "${OCP_PROJECT}" --timeout=5m || { echo "Error: Backend deployment failed to rollout within timeout. Check 'oc get pods -n ${OCP_PROJECT}'. Exiting."; exit 1; }

echo "--- Deployment and Builds Complete! ---"
echo "Your application should now be running."

echo ""
echo "--- Access Information ---"
# Fetch service ports dynamically for more robust output
FRONTEND_SERVICE_PORT=$(kubectl get service "${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-frontend-service" -n "${OCP_PROJECT}" -o jsonpath='{.spec.ports[?(@.name=="http")].port}' || echo "N/A")
BACKEND_SERVICE_PORT=$(kubectl get service "${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-backend-service" -n "${OCP_PROJECT}" -o jsonpath='{.spec.ports[?(@.name=="http")].port}' || echo "N/A")

FRONTEND_ROUTE_NAME="${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-frontend-route"
FRONTEND_ROUTE_HOST=$(oc get route "${FRONTEND_ROUTE_NAME}" -n "${OCP_PROJECT}" -o jsonpath='{.spec.host}' || echo "N/A")

if [ "${FRONTEND_ROUTE_HOST}" != "N/A" ]; then
    echo "Frontend URL (via Route):   http://${FRONTEND_ROUTE_HOST}"
else
    echo "Frontend Route not found or hostname not provisioned. Check 'oc get route ${FRONTEND_ROUTE_NAME} -n ${OCP_PROJECT}'"
fi

echo "Backend internal URL (used by frontend): http://${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-backend-service:${BACKEND_SERVICE_PORT}/get-count"
echo ""
echo "To view build logs: 'oc logs -f bc/${FRONTEND_BC_NAME}' or 'oc logs -f bc/${BACKEND_BC_NAME}'"
echo "To view app logs: 'oc logs -f deployment/${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-frontend' or 'oc logs -f deployment/${HELM_RELEASE_NAME}-${FULL_CHART_NAME}-backend'"
echo ""
echo "Script finished."
