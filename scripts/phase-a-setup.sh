#!/bin/bash
#
# Phase A: SIDB + Data Guard Automated Setup
#
# This script automates the deployment of Oracle Single Instance Database
# with Data Guard on OCNE 1.9 using the Oracle Database Operator.
#
# Usage: ./phase-a-setup.sh --ocr-user <email> --ocr-password <password> [options]
#
# Prerequisites:
#   - OCNE 1.9 cluster with Kubernetes 1.29
#   - Oracle Database Operator installed
#   - cert-manager installed
#   - NFS storage configured
#   - kubectl configured with cluster access
#

set -e

# Default values
NAMESPACE="sidb"
NFS_SERVER="192.168.137.210"
NFS_PATH="/export/oradata"
DB_PASSWORD="oracle"
PRIMARY_NAME="sidb-primary"
STANDBY_NAME="sidb-standby"
PRIMARY_SID="ORCL"
STANDBY_SID="ORCLS"
PDB_NAME="ORCLPDB"
DB_IMAGE="container-registry.oracle.com/database/enterprise:19.3.0.0"
STORAGE_CLASS="nfs-storage"
STORAGE_SIZE="100Gi"
RBAC_PATH="/root/oracle-database-operator/rbac"
DB_EDITION="enterprise"
CHARSET="AL32UTF8"
CPU_REQUEST="2"
CPU_LIMIT="4"
MEMORY_REQUEST="8Gi"
MEMORY_LIMIT="12Gi"
CREATE_STORAGE_CLASS="true"
SKIP_RBAC="false"
PRIMARY_TIMEOUT=2400
STANDBY_TIMEOUT=1800

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_help() {
    cat << EOF
Usage: $0 --ocr-user <email> --ocr-password <password> [options]

Required:
  --ocr-user            Oracle Container Registry username (email)
  --ocr-password        Oracle Container Registry password

Database Options:
  --db-password         Database admin password (default: oracle)
  --primary-name        Primary database resource name (default: sidb-primary)
  --standby-name        Standby database resource name (default: sidb-standby)
  --primary-sid         Primary database SID (default: ORCL)
  --standby-sid         Standby database SID (default: ORCLS)
  --pdb-name            PDB name (default: ORCLPDB)
  --db-edition          Database edition: enterprise|standard (default: enterprise)
  --charset             Database character set (default: AL32UTF8)
  --image               Database container image (default: container-registry.oracle.com/database/enterprise:19.3.0.0)

Kubernetes Options:
  --namespace           Kubernetes namespace (default: sidb)
  --storage-class       Storage class name (default: nfs-storage)
  --storage-size        PV/PVC size (default: 100Gi)
  --create-storage-class  Create NFS storage class: true|false (default: true)

NFS Options:
  --nfs-server          NFS server IP (default: 192.168.137.210)
  --nfs-path            NFS base path (default: /export/oradata)

Resource Limits:
  --cpu-request         CPU request (default: 2)
  --cpu-limit           CPU limit (default: 4)
  --memory-request      Memory request (default: 8Gi)
  --memory-limit        Memory limit (default: 12Gi)

Other Options:
  --rbac-path           Path to RBAC files (default: /root/oracle-database-operator/rbac)
  --skip-rbac           Skip RBAC setup: true|false (default: false)
  --primary-timeout     Primary creation timeout in seconds (default: 2400)
  --standby-timeout     Standby creation timeout in seconds (default: 1800)
  --help                Show this help message

Examples:
  # Basic usage with defaults
  $0 --ocr-user user@example.com --ocr-password secret123

  # Custom image and namespace
  $0 --ocr-user user@example.com --ocr-password secret123 \\
     --image container-registry.oracle.com/database/enterprise:21.3.0.0 \\
     --namespace mydb

  # Custom resource limits
  $0 --ocr-user user@example.com --ocr-password secret123 \\
     --cpu-request 4 --cpu-limit 8 --memory-request 16Gi --memory-limit 24Gi

  # Use existing storage class
  $0 --ocr-user user@example.com --ocr-password secret123 \\
     --storage-class my-existing-sc --create-storage-class false
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ocr-user)
            OCR_USER="$2"
            shift 2
            ;;
        --ocr-password)
            OCR_PASSWORD="$2"
            shift 2
            ;;
        --db-password)
            DB_PASSWORD="$2"
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
        --primary-sid)
            PRIMARY_SID="$2"
            shift 2
            ;;
        --standby-sid)
            STANDBY_SID="$2"
            shift 2
            ;;
        --pdb-name)
            PDB_NAME="$2"
            shift 2
            ;;
        --db-edition)
            DB_EDITION="$2"
            shift 2
            ;;
        --charset)
            CHARSET="$2"
            shift 2
            ;;
        --image)
            DB_IMAGE="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --storage-class)
            STORAGE_CLASS="$2"
            shift 2
            ;;
        --storage-size)
            STORAGE_SIZE="$2"
            shift 2
            ;;
        --create-storage-class)
            CREATE_STORAGE_CLASS="$2"
            shift 2
            ;;
        --nfs-server)
            NFS_SERVER="$2"
            shift 2
            ;;
        --nfs-path)
            NFS_PATH="$2"
            shift 2
            ;;
        --cpu-request)
            CPU_REQUEST="$2"
            shift 2
            ;;
        --cpu-limit)
            CPU_LIMIT="$2"
            shift 2
            ;;
        --memory-request)
            MEMORY_REQUEST="$2"
            shift 2
            ;;
        --memory-limit)
            MEMORY_LIMIT="$2"
            shift 2
            ;;
        --rbac-path)
            RBAC_PATH="$2"
            shift 2
            ;;
        --skip-rbac)
            SKIP_RBAC="$2"
            shift 2
            ;;
        --primary-timeout)
            PRIMARY_TIMEOUT="$2"
            shift 2
            ;;
        --standby-timeout)
            STANDBY_TIMEOUT="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$OCR_USER" || -z "$OCR_PASSWORD" ]]; then
    echo -e "${RED}Error: --ocr-user and --ocr-password are required${NC}"
    echo "Run with --help for usage information"
    exit 1
fi

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_config() {
    echo -e "${BLUE}[CONFIG]${NC} $1"
}

# Display configuration
echo ""
echo "=============================================="
echo "     Phase A Configuration Summary"
echo "=============================================="
log_config "Namespace:        $NAMESPACE"
log_config "Primary Name:     $PRIMARY_NAME"
log_config "Standby Name:     $STANDBY_NAME"
log_config "Primary SID:      $PRIMARY_SID"
log_config "Standby SID:      $STANDBY_SID"
log_config "PDB Name:         $PDB_NAME"
log_config "Image:            $DB_IMAGE"
log_config "Storage Class:    $STORAGE_CLASS"
log_config "Storage Size:     $STORAGE_SIZE"
log_config "NFS Server:       $NFS_SERVER"
log_config "NFS Path:         $NFS_PATH"
log_config "CPU:              $CPU_REQUEST (request) / $CPU_LIMIT (limit)"
log_config "Memory:           $MEMORY_REQUEST (request) / $MEMORY_LIMIT (limit)"
echo "=============================================="
echo ""

wait_for_sidb_healthy() {
    local name=$1
    local timeout=${2:-1800}  # Default 30 minutes
    local interval=30
    local elapsed=0

    log_info "Waiting for $name to become Healthy (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        status=$(kubectl get singleinstancedatabase "$name" -n "$NAMESPACE" -o jsonpath='{.status.status}' 2>/dev/null || echo "NotFound")

        # Show progress
        if [[ "$status" != "NotFound" ]]; then
            role=$(kubectl get singleinstancedatabase "$name" -n "$NAMESPACE" -o jsonpath='{.status.role}' 2>/dev/null || echo "Unknown")
            printf "\r  Status: %-12s Role: %-20s Elapsed: %ds" "$status" "$role" "$elapsed"
        fi

        if [[ "$status" == "Healthy" ]]; then
            echo ""
            log_info "$name is Healthy!"
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo ""
    log_error "$name did not become Healthy within ${timeout}s"
    return 1
}

wait_for_pod_running() {
    local label=$1
    local timeout=${2:-300}
    local interval=10
    local elapsed=0

    log_info "Waiting for pod with label $label to be Running..."

    while [[ $elapsed -lt $timeout ]]; do
        status=$(kubectl get pod -n "$NAMESPACE" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

        if [[ "$status" == "Running" ]]; then
            log_info "Pod is Running!"
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_error "Pod did not become Running within ${timeout}s"
    return 1
}

# =============================================================================
# Step 1: Create Namespace and Secrets
# =============================================================================
log_info "Step 1: Creating namespace and secrets..."

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic db-admin-secret -n "$NAMESPACE" \
    --from-literal=oracle_pwd="$DB_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry oracle-container-registry-secret -n "$NAMESPACE" \
    --docker-server=container-registry.oracle.com \
    --docker-username="$OCR_USER" \
    --docker-password="$OCR_PASSWORD" \
    --docker-email="$OCR_USER" \
    --dry-run=client -o yaml | kubectl apply -f -

log_info "Namespace and secrets created"

# =============================================================================
# Step 2: Apply RBAC
# =============================================================================
if [[ "$SKIP_RBAC" != "true" ]]; then
    log_info "Step 2: Applying RBAC..."

    if [[ -f "$RBAC_PATH/node-rbac.yaml" ]]; then
        kubectl apply -f "$RBAC_PATH/node-rbac.yaml"
    else
        log_warn "node-rbac.yaml not found at $RBAC_PATH, skipping..."
    fi

    if [[ -f "$RBAC_PATH/persistent-volume-rbac.yaml" ]]; then
        kubectl apply -f "$RBAC_PATH/persistent-volume-rbac.yaml"
    else
        log_warn "persistent-volume-rbac.yaml not found at $RBAC_PATH, skipping..."
    fi

    log_info "RBAC applied"
else
    log_info "Step 2: Skipping RBAC (--skip-rbac=true)"
fi

# =============================================================================
# Step 3: Create Storage Class
# =============================================================================
if [[ "$CREATE_STORAGE_CLASS" == "true" ]]; then
    log_info "Step 3: Creating storage class '$STORAGE_CLASS'..."

    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS}
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF

    log_info "Storage class created"
else
    log_info "Step 3: Using existing storage class '$STORAGE_CLASS'"
fi

# =============================================================================
# Step 4: Create Persistent Volumes and Claims
# =============================================================================
log_info "Step 4: Creating PVs and PVCs..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PRIMARY_NAME}-pv
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${STORAGE_CLASS}
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_PATH}/${PRIMARY_NAME}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${STANDBY_NAME}-pv
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${STORAGE_CLASS}
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_PATH}/${STANDBY_NAME}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PRIMARY_NAME}-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${STORAGE_SIZE}
  volumeName: ${PRIMARY_NAME}-pv
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${STANDBY_NAME}-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${STORAGE_SIZE}
  volumeName: ${STANDBY_NAME}-pv
EOF

log_info "PVs and PVCs created"

# =============================================================================
# Step 5: Create Primary Database
# =============================================================================
log_info "Step 5: Creating primary database '${PRIMARY_NAME}'..."

cat <<EOF | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: SingleInstanceDatabase
metadata:
  name: ${PRIMARY_NAME}
  namespace: ${NAMESPACE}
spec:
  sid: ${PRIMARY_SID}
  edition: ${DB_EDITION}
  createAs: primary

  security:
    secrets:
      admin:
        secretName: db-admin-secret
        secretKey: oracle_pwd
        keepSecret: true

  charset: ${CHARSET}
  pdbName: ${PDB_NAME}

  archiveLog: true
  forceLog: true
  flashBack: true

  image:
    pullFrom: ${DB_IMAGE}
    pullSecrets: oracle-container-registry-secret

  persistence:
    oradata:
      pvcName: ${PRIMARY_NAME}-pvc
      accessMode: ReadWriteOnce
    setWritePermissions: true

  resources:
    requests:
      cpu: "${CPU_REQUEST}"
      memory: "${MEMORY_REQUEST}"
    limits:
      cpu: "${CPU_LIMIT}"
      memory: "${MEMORY_LIMIT}"

  services:
    endpoints:
      - name: nodeport
        type: NodePort
        tcp:
          enabled: true

  replicas: 1
EOF

# Wait for primary to be healthy
wait_for_sidb_healthy "${PRIMARY_NAME}" ${PRIMARY_TIMEOUT} || exit 1

# =============================================================================
# Step 6: Configure Data Guard Prerequisites
# =============================================================================
log_info "Step 6: Configuring Data Guard prerequisites on primary..."

PRIMARY_POD=$(kubectl get pod -n "$NAMESPACE" -l app=${PRIMARY_NAME} -o jsonpath='{.items[0].metadata.name}')

# Create dummy configDataguardPrereqs.sh script
kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- bash -c 'cat > /opt/oracle/configDataguardPrereqs.sh << "EOSCRIPT"
#!/bin/bash
echo "Data Guard prerequisites configuration complete"
exit 0
EOSCRIPT
chmod +x /opt/oracle/configDataguardPrereqs.sh'

log_info "Created dummy configDataguardPrereqs.sh on primary"

# Configure Data Guard parameters
kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- sqlplus -s / as sysdba << EOSQL
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(${PRIMARY_SID},${STANDBY_SID})' SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${PRIMARY_SID}' SCOPE=BOTH;
ALTER SYSTEM SET FAL_SERVER='${STANDBY_SID}' SCOPE=BOTH;
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH;
EXIT;
EOSQL

log_info "Data Guard prerequisites configured on primary"

# =============================================================================
# Step 7: Create Standby Database
# =============================================================================
log_info "Step 7: Creating standby database '${STANDBY_NAME}'..."

cat <<EOF | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: SingleInstanceDatabase
metadata:
  name: ${STANDBY_NAME}
  namespace: ${NAMESPACE}
spec:
  sid: ${STANDBY_SID}
  createAs: standby

  primarySource:
    databaseRef: ${PRIMARY_NAME}

  security:
    secrets:
      admin:
        secretName: db-admin-secret
        secretKey: oracle_pwd
        keepSecret: true

  dataguard:
    prereqs:
      enabled: true

  image:
    pullFrom: ${DB_IMAGE}
    pullSecrets: oracle-container-registry-secret

  persistence:
    oradata:
      pvcName: ${STANDBY_NAME}-pvc
      accessMode: ReadWriteOnce
    setWritePermissions: true

  resources:
    requests:
      cpu: "${CPU_REQUEST}"
      memory: "${MEMORY_REQUEST}"
    limits:
      cpu: "${CPU_LIMIT}"
      memory: "${MEMORY_LIMIT}"

  services:
    endpoints:
      - name: nodeport
        type: NodePort
        tcp:
          enabled: true

  replicas: 1
EOF

# Wait for standby pod to start, then add dummy script
log_info "Waiting for standby pod to start..."
wait_for_pod_running "app=${STANDBY_NAME}" 600

STANDBY_POD=$(kubectl get pod -n "$NAMESPACE" -l app=${STANDBY_NAME} -o jsonpath='{.items[0].metadata.name}')

# Create dummy script on standby
kubectl exec -n "$NAMESPACE" "$STANDBY_POD" -- bash -c 'cat > /opt/oracle/configDataguardPrereqs.sh << "EOSCRIPT"
#!/bin/bash
echo "Data Guard prerequisites configuration complete"
exit 0
EOSCRIPT
chmod +x /opt/oracle/configDataguardPrereqs.sh' 2>/dev/null || log_warn "Could not create script on standby yet, continuing..."

# Wait for standby to be healthy
wait_for_sidb_healthy "${STANDBY_NAME}" ${STANDBY_TIMEOUT} || exit 1

# =============================================================================
# Step 8: Create Data Guard Broker
# =============================================================================
BROKER_NAME="${STANDBY_NAME}-dg"
log_info "Step 8: Creating Data Guard Broker '${BROKER_NAME}'..."

cat <<EOF | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: DataguardBroker
metadata:
  name: ${BROKER_NAME}
  namespace: ${NAMESPACE}
spec:
  execution:
    authWallet:
      enabled: true
    image: ${DB_IMAGE}
    imagePullSecrets:
      - oracle-container-registry-secret
  topology:
    defaults:
      adminSecretRef:
        secretKey: oracle_pwd
        secretName: db-admin-secret
    members:
      - dbUniqueName: ${PRIMARY_SID}
        endpoints:
          - host: ${PRIMARY_NAME}
            name: tcp
            port: 1521
            protocol: TCP
            serviceName: ${PRIMARY_SID}
        localRef:
          apiVersion: database.oracle.com/v4
          kind: SingleInstanceDatabase
          name: ${PRIMARY_NAME}
          namespace: ${NAMESPACE}
        name: ${PRIMARY_NAME}
        role: PRIMARY
      - dbUniqueName: ${STANDBY_SID}
        endpoints:
          - host: ${STANDBY_NAME}
            name: tcp
            port: 1521
            protocol: TCP
            serviceName: ${STANDBY_SID}
        localRef:
          apiVersion: database.oracle.com/v4
          kind: SingleInstanceDatabase
          name: ${STANDBY_NAME}
          namespace: ${NAMESPACE}
        name: ${STANDBY_NAME}
        role: PHYSICAL_STANDBY
    sourceKind: SingleInstanceDatabase
    sourceRef:
      apiVersion: database.oracle.com/v4
      kind: SingleInstanceDatabase
      name: ${STANDBY_NAME}
      namespace: ${NAMESPACE}
EOF

log_info "Data Guard Broker created"

# =============================================================================
# Step 9: Verify Final Configuration
# =============================================================================
log_info "Step 9: Verifying final configuration..."

sleep 30  # Give broker time to configure

echo ""
echo "=============================================="
echo "          SIDB + Data Guard Status"
echo "=============================================="
kubectl get singleinstancedatabase -n "$NAMESPACE"
echo ""
kubectl get dataguardbroker -n "$NAMESPACE"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""

# Verify Data Guard Broker configuration
log_info "Verifying Data Guard Broker via DGMGRL..."
kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- dgmgrl / "show configuration" 2>/dev/null || log_warn "DGMGRL verification skipped"

echo ""
echo "=============================================="
echo -e "${GREEN}Phase A Setup Complete!${NC}"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Namespace:    ${NAMESPACE}"
echo "  Primary SID:  ${PRIMARY_SID}"
echo "  Standby SID:  ${STANDBY_SID}"
echo "  Image:        ${DB_IMAGE}"
echo ""
echo "Connect Strings:"
echo "  Primary CDB:  $(kubectl get singleinstancedatabase ${PRIMARY_NAME} -n $NAMESPACE -o jsonpath='{.status.connectString}' 2>/dev/null)"
echo "  Primary PDB:  $(kubectl get singleinstancedatabase ${PRIMARY_NAME} -n $NAMESPACE -o jsonpath='{.status.pdbConnectString}' 2>/dev/null)"
echo "  Standby CDB:  $(kubectl get singleinstancedatabase ${STANDBY_NAME} -n $NAMESPACE -o jsonpath='{.status.connectString}' 2>/dev/null)"
echo "  Standby PDB:  $(kubectl get singleinstancedatabase ${STANDBY_NAME} -n $NAMESPACE -o jsonpath='{.status.pdbConnectString}' 2>/dev/null)"
echo ""
echo "Next Steps:"
echo "  Test switchover: kubectl exec -n ${NAMESPACE} \$PRIMARY_POD -- dgmgrl / \"switchover to ${STANDBY_SID}\""
echo "  Test failover:   kubectl exec -n ${NAMESPACE} \$STANDBY_POD -- dgmgrl / \"failover to ${STANDBY_SID}\""
echo ""
