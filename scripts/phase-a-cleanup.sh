#!/bin/bash
#
# Phase A: SIDB + Data Guard Cleanup
#
# This script removes all Phase A resources from the cluster.
#
# Usage: ./phase-a-cleanup.sh [options]
#

set -e

# Default values
NAMESPACE="sidb"
PRIMARY_NAME="sidb-primary"
STANDBY_NAME="sidb-standby"
FORCE=false
DELETE_NAMESPACE=false
CLEAN_NFS=false
NFS_SERVER=""
NFS_PATH="/export/oradata"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_help() {
    cat << EOF
Usage: $0 [options]

Options:
  --namespace         Kubernetes namespace (default: sidb)
  --primary-name      Primary database name (default: sidb-primary)
  --standby-name      Standby database name (default: sidb-standby)
  --force             Skip confirmation prompts
  --delete-namespace  Also delete the namespace
  --clean-nfs         Clean NFS directories (requires --nfs-server)
  --nfs-server        NFS server hostname for cleanup
  --nfs-path          NFS base path (default: /export/oradata)
  --help              Show this help message

Examples:
  # Interactive cleanup with defaults
  $0

  # Force cleanup without prompts
  $0 --force

  # Cleanup custom names
  $0 --primary-name mydb-primary --standby-name mydb-standby

  # Full cleanup including namespace and NFS
  $0 --force --delete-namespace --clean-nfs --nfs-server ocne-op
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --primary-name)
            PRIMARY_NAME="$2"
            shift 2
            ;;
        --standby-name)
            STANDBY_NAME="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --delete-namespace)
            DELETE_NAMESPACE=true
            shift
            ;;
        --clean-nfs)
            CLEAN_NFS=true
            shift
            ;;
        --nfs-server)
            NFS_SERVER="$2"
            shift 2
            ;;
        --nfs-path)
            NFS_PATH="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

BROKER_NAME="${STANDBY_NAME}-dg"

if [[ "$FORCE" != "true" ]]; then
    echo -e "${YELLOW}WARNING: This will delete the following resources:${NC}"
    echo "  - DataGuardBroker: ${BROKER_NAME}"
    echo "  - SingleInstanceDatabase: ${STANDBY_NAME}"
    echo "  - SingleInstanceDatabase: ${PRIMARY_NAME}"
    echo "  - PVC: ${PRIMARY_NAME}-pvc, ${STANDBY_NAME}-pvc"
    echo "  - PV: ${PRIMARY_NAME}-pv, ${STANDBY_NAME}-pv"
    echo "  - Secrets: db-admin-secret, oracle-container-registry-secret"
    if [[ "$DELETE_NAMESPACE" == "true" ]]; then
        echo "  - Namespace: ${NAMESPACE}"
    fi
    if [[ "$CLEAN_NFS" == "true" && -n "$NFS_SERVER" ]]; then
        echo "  - NFS data: ${NFS_SERVER}:${NFS_PATH}/${PRIMARY_NAME}/*"
        echo "  - NFS data: ${NFS_SERVER}:${NFS_PATH}/${STANDBY_NAME}/*"
    fi
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Delete DataGuardBroker first
log_info "Deleting DataGuardBroker '${BROKER_NAME}'..."
kubectl delete dataguardbroker "${BROKER_NAME}" -n "$NAMESPACE" --ignore-not-found=true --timeout=120s || true

# Delete standby database
log_info "Deleting standby database '${STANDBY_NAME}'..."
kubectl delete singleinstancedatabase "${STANDBY_NAME}" -n "$NAMESPACE" --ignore-not-found=true --timeout=300s || true

# Delete primary database
log_info "Deleting primary database '${PRIMARY_NAME}'..."
kubectl delete singleinstancedatabase "${PRIMARY_NAME}" -n "$NAMESPACE" --ignore-not-found=true --timeout=300s || true

# Wait for pods to terminate
log_info "Waiting for pods to terminate..."
kubectl wait --for=delete pod -l app="${PRIMARY_NAME}" -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
kubectl wait --for=delete pod -l app="${STANDBY_NAME}" -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

# Delete PVCs
log_info "Deleting PVCs..."
kubectl delete pvc "${PRIMARY_NAME}-pvc" "${STANDBY_NAME}-pvc" -n "$NAMESPACE" --ignore-not-found=true || true

# Delete PVs
log_info "Deleting PVs..."
kubectl delete pv "${PRIMARY_NAME}-pv" "${STANDBY_NAME}-pv" --ignore-not-found=true || true

# Delete secrets
log_info "Deleting secrets..."
kubectl delete secret db-admin-secret oracle-container-registry-secret -n "$NAMESPACE" --ignore-not-found=true || true

# Clean NFS data if requested
if [[ "$CLEAN_NFS" == "true" && -n "$NFS_SERVER" ]]; then
    log_info "Cleaning NFS data on ${NFS_SERVER}..."
    ssh root@"${NFS_SERVER}" "rm -rf ${NFS_PATH}/${PRIMARY_NAME}/* ${NFS_PATH}/${STANDBY_NAME}/*" 2>/dev/null || log_warn "Could not clean NFS data"
fi

# Delete namespace if requested
if [[ "$DELETE_NAMESPACE" == "true" ]]; then
    log_info "Deleting namespace '${NAMESPACE}'..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true || true
fi

echo ""
log_info "Phase A cleanup complete!"

if [[ "$CLEAN_NFS" != "true" || -z "$NFS_SERVER" ]]; then
    echo ""
    echo "Note: NFS directories may still contain data."
    echo "To clean NFS data manually, run on the NFS server:"
    echo "  rm -rf ${NFS_PATH}/${PRIMARY_NAME}/* ${NFS_PATH}/${STANDBY_NAME}/*"
fi
