# Phase A: SIDB + Data Guard Setup Guide

This document provides step-by-step instructions to deploy Oracle Single Instance Database with Data Guard on OCNE 1.9 using the Oracle Database Operator.

---

## Prerequisites Completed

- OCNE 1.9 cluster with Kubernetes 1.29
- Oracle Database Operator installed in `oracle-database-operator-system` namespace
- cert-manager installed
- NFS storage configured on ocne-op at `/export/oradata`
- Oracle Container Registry access configured

---

## Step 1: Create Namespace and Secrets

### 1.1 Create SIDB namespace (if not exists)
```bash
kubectl create namespace sidb
```

### 1.2 Create admin password secret
```bash
kubectl create secret generic db-admin-secret -n sidb \
  --from-literal=oracle_pwd='oracle'
```

### 1.3 Create Oracle Container Registry pull secret
```bash
kubectl create secret docker-registry oracle-container-registry-secret -n sidb \
  --docker-server=container-registry.oracle.com \
  --docker-username='YOUR_EMAIL' \
  --docker-password='YOUR_PASSWORD' \
  --docker-email='YOUR_EMAIL'
```

---

## Step 2: Apply RBAC for SIDB

```bash
kubectl apply -f /root/oracle-database-operator/rbac/node-rbac.yaml
kubectl apply -f /root/oracle-database-operator/rbac/persistent-volume-rbac.yaml
```

---

## Step 3: Create Storage Class and Directories

### 3.1 Create NFS storage class
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF
```

### 3.2 Create NFS directories (on ocne-op)
```bash
mkdir -p /export/oradata/sidb-primary /export/oradata/sidb-standby
chown -R 54321:54321 /export/oradata/sidb-primary /export/oradata/sidb-standby
chmod 775 /export/oradata/sidb-primary /export/oradata/sidb-standby
```

---

## Step 4: Create Persistent Volumes and Claims

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: sidb-primary-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-storage
  nfs:
    server: 192.168.137.210
    path: /export/oradata/sidb-primary
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: sidb-standby-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-storage
  nfs:
    server: 192.168.137.210
    path: /export/oradata/sidb-standby
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sidb-primary-pvc
  namespace: sidb
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-storage
  resources:
    requests:
      storage: 100Gi
  volumeName: sidb-primary-pv
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sidb-standby-pvc
  namespace: sidb
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-storage
  resources:
    requests:
      storage: 100Gi
  volumeName: sidb-standby-pv
EOF
```

---

## Step 5: Create Primary Database

### 5.1 Apply Primary SIDB manifest
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: SingleInstanceDatabase
metadata:
  name: sidb-primary
  namespace: sidb
spec:
  sid: ORCL
  edition: enterprise
  createAs: primary

  security:
    secrets:
      admin:
        secretName: db-admin-secret
        secretKey: oracle_pwd
        keepSecret: true

  charset: AL32UTF8
  pdbName: ORCLPDB

  archiveLog: true
  forceLog: true
  flashBack: true

  image:
    pullFrom: container-registry.oracle.com/database/enterprise:19.3.0.0
    pullSecrets: oracle-container-registry-secret

  persistence:
    oradata:
      pvcName: sidb-primary-pvc
      accessMode: ReadWriteOnce
    setWritePermissions: true

  resources:
    requests:
      cpu: "2"
      memory: "8Gi"
    limits:
      cpu: "4"
      memory: "12Gi"

  services:
    endpoints:
      - name: nodeport
        type: NodePort
        tcp:
          enabled: true

  replicas: 1
EOF
```

### 5.2 Monitor primary creation (takes ~20 minutes)
```bash
# Watch pods
kubectl get pods -n sidb -w

# Check logs
kubectl logs -n sidb -l app=sidb-primary -f --tail=20

# Check SIDB status
kubectl get singleinstancedatabase -n sidb
```

### 5.3 Wait until primary is Healthy
```bash
# Expected output:
# NAME           EDITION      STATUS    ROLE      VERSION      CONNECT STR
# sidb-primary   Enterprise   Healthy   PRIMARY   19.3.0.0.0   192.168.137.x:xxxxx/ORCL
```

---

## Step 6: Configure Data Guard Prerequisites on Primary

### 6.1 Create dummy configDataguardPrereqs.sh script
The `enterprise:19.3.0.0` image lacks the Data Guard prereqs script. Create a dummy one:

```bash
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-primary -o jsonpath='{.items[0].metadata.name}') -- bash -c 'cat > /opt/oracle/configDataguardPrereqs.sh << "EOSCRIPT"
#!/bin/bash
echo "Data Guard prerequisites configuration complete"
exit 0
EOSCRIPT
chmod +x /opt/oracle/configDataguardPrereqs.sh'
```

### 6.2 Configure Data Guard parameters via SQL
```bash
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-primary -o jsonpath='{.items[0].metadata.name}') -- sqlplus -s / as sysdba << 'EOF'
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(ORCL,ORCLS)' SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=ORCL' SCOPE=BOTH;
ALTER SYSTEM SET FAL_SERVER='ORCLS' SCOPE=BOTH;
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH;
EXIT;
EOF
```

---

## Step 7: Create Standby Database

### 7.1 Apply Standby SIDB manifest
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: SingleInstanceDatabase
metadata:
  name: sidb-standby
  namespace: sidb
spec:
  sid: ORCLS
  createAs: standby

  primarySource:
    databaseRef: sidb-primary

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
    pullFrom: container-registry.oracle.com/database/enterprise:19.3.0.0
    pullSecrets: oracle-container-registry-secret

  persistence:
    oradata:
      pvcName: sidb-standby-pvc
      accessMode: ReadWriteOnce
    setWritePermissions: true

  resources:
    requests:
      cpu: "2"
      memory: "8Gi"
    limits:
      cpu: "4"
      memory: "12Gi"

  services:
    endpoints:
      - name: nodeport
        type: NodePort
        tcp:
          enabled: true

  replicas: 1
EOF
```

### 7.2 Monitor standby creation (takes ~10 minutes)
```bash
kubectl get pods -n sidb -w
kubectl logs -n sidb -l app=sidb-standby -f --tail=20
kubectl get singleinstancedatabase -n sidb
```

### 7.3 Add dummy script to standby (after pod starts)
```bash
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-standby -o jsonpath='{.items[0].metadata.name}') -- bash -c 'cat > /opt/oracle/configDataguardPrereqs.sh << "EOSCRIPT"
#!/bin/bash
echo "Data Guard prerequisites configuration complete"
exit 0
EOSCRIPT
chmod +x /opt/oracle/configDataguardPrereqs.sh'
```

---

## Step 8: Create Data Guard Broker

### 8.1 Apply DataGuardBroker manifest
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: DataguardBroker
metadata:
  name: sidb-standby-dg
  namespace: sidb
spec:
  execution:
    authWallet:
      enabled: true
    image: container-registry.oracle.com/database/enterprise:19.3.0.0
    imagePullSecrets:
      - oracle-container-registry-secret
  topology:
    defaults:
      adminSecretRef:
        secretKey: oracle_pwd
        secretName: db-admin-secret
    members:
      - dbUniqueName: ORCL
        endpoints:
          - host: sidb-primary
            name: tcp
            port: 1521
            protocol: TCP
            serviceName: ORCL
        localRef:
          apiVersion: database.oracle.com/v4
          kind: SingleInstanceDatabase
          name: sidb-primary
          namespace: sidb
        name: sidb-primary
        role: PRIMARY
      - dbUniqueName: ORCLS
        endpoints:
          - host: sidb-standby
            name: tcp
            port: 1521
            protocol: TCP
            serviceName: ORCLS
        localRef:
          apiVersion: database.oracle.com/v4
          kind: SingleInstanceDatabase
          name: sidb-standby
          namespace: sidb
        name: sidb-standby
        role: PHYSICAL_STANDBY
    sourceKind: SingleInstanceDatabase
    sourceRef:
      apiVersion: database.oracle.com/v4
      kind: SingleInstanceDatabase
      name: sidb-standby
      namespace: sidb
EOF
```

### 8.2 Monitor broker status
```bash
kubectl get dataguardbroker -n sidb
kubectl get pods -n sidb
```

---

## Step 9: Verify Final Configuration

### 9.1 Check all resources
```bash
kubectl get singleinstancedatabase -n sidb
kubectl get dataguardbroker -n sidb
kubectl get pods -n sidb
```

**Expected output:**
```
NAME           EDITION      STATUS    ROLE               VERSION      CONNECT STR
sidb-primary   Enterprise   Healthy   PRIMARY            19.3.0.0.0   192.168.137.x:xxxxx/ORCL
sidb-standby   Enterprise   Healthy   PHYSICAL_STANDBY   19.3.0.0.0   192.168.137.x:xxxxx/ORCLS

NAME              PRIMARY   STANDBYS   PROTECTION MODE   STATUS    FSFO
sidb-standby-dg   ORCL      ORCLS      MaxPerformance    Healthy   false
```

### 9.2 Verify Data Guard Broker via DGMGRL
```bash
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-primary -o jsonpath='{.items[0].metadata.name}') -- dgmgrl / "show configuration"
```

**Expected output:**
```
Configuration - dg_config

  Protection Mode: MaxPerformance
  Members:
  orcl  - Primary database
    orcls - Physical standby database

Fast-Start Failover:  Disabled

Configuration Status:
SUCCESS
```

### 9.3 Verify database roles
```bash
# Primary
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-primary -o jsonpath='{.items[0].metadata.name}') -- sqlplus -s / as sysdba <<< "SELECT DATABASE_ROLE, OPEN_MODE FROM V\$DATABASE;"

# Standby
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-standby -o jsonpath='{.items[0].metadata.name}') -- sqlplus -s / as sysdba <<< "SELECT DATABASE_ROLE, OPEN_MODE FROM V\$DATABASE;"
```

---

## Troubleshooting

### Common Issues

1. **Pod keeps restarting during creation**
   - Check memory limits - database creation needs adequate memory
   - Use `enterprise:19.3.0.0` instead of `enterprise_ru` (see `troubleshooting-enterprise_ru-image.md`)

2. **configDataguardPrereqs.sh not found**
   - The script is missing in `enterprise:19.3.0.0` image
   - Create dummy script as shown in Step 6.1

3. **Standby shows Unhealthy before broker setup**
   - This is normal - standby becomes fully Healthy after DataGuardBroker is configured

4. **Authentication failed for image pull**
   - Ensure license is accepted at container-registry.oracle.com
   - Recreate pull secret with correct credentials

### Useful Commands
```bash
# Check pod logs
kubectl logs -n sidb <pod-name> --tail=50

# Check SIDB details
kubectl describe singleinstancedatabase <name> -n sidb

# Check broker details
kubectl describe dataguardbroker <name> -n sidb

# Execute SQL on primary
kubectl exec -n sidb <primary-pod> -- sqlplus / as sysdba

# Check Data Guard status
kubectl exec -n sidb <primary-pod> -- dgmgrl / "show configuration"
```

---

## Architecture Summary

```
+------------------+          +------------------+
|   sidb-primary   |          |   sidb-standby   |
|   (ocne-w1)      |  <---->  |   (ocne-w2)      |
|                  |  Redo    |                  |
|  ORCL (PRIMARY)  |  Logs    |  ORCLS (STANDBY) |
+------------------+          +------------------+
         |                             |
         +----------+    +-------------+
                    |    |
              +-----v----v-----+
              | DataGuardBroker|
              | (broker runner)|
              +----------------+
                    |
         +---------+----------+
         |                    |
+--------v--------+  +--------v--------+
|  sidb-primary   |  |  sidb-standby   |
|     Service     |  |     Service     |
| (NodePort)      |  | (NodePort)      |
+-----------------+  +-----------------+
```

---

## Connect Strings

| Database | Connect String | NodePort |
|----------|---------------|----------|
| Primary CDB | `192.168.137.222:31979/ORCL` | 31979 |
| Primary PDB | `192.168.137.222:31979/ORCLPDB` | 31979 |
| Standby CDB | `192.168.137.211:30900/ORCLS` | 30900 |
| Standby PDB | `192.168.137.211:30900/ORCLPDB1` | 30900 |

---

## Next Steps

1. **Test switchover:**
   ```bash
   kubectl exec -n sidb <primary-pod> -- dgmgrl / "switchover to orcls"
   ```

2. **Test failover:**
   ```bash
   kubectl exec -n sidb <standby-pod> -- dgmgrl / "failover to orcls"
   ```

3. **Enable Fast-Start Failover (FSFO)** - requires observer setup

---

## Complete Implementation Walkthrough (Tested September 2026)

This section documents the exact steps that worked, including all errors encountered and their fixes.

### Pre-Step: Verify Cluster Health

```bash
# Check all nodes are Ready
kubectl get nodes

# Check Oracle Database Operator is running
kubectl get pods -n oracle-database-operator-system

# Check cert-manager is running
kubectl get pods -n cert-manager
```

### Step 1: Prepare NFS Storage (on ocne-op)

```bash
# SSH to NFS server
ssh root@ocne-op

# Create directories for primary and standby
mkdir -p /export/oradata/sidb-primary /export/oradata/sidb-standby

# Set ownership (Oracle runs as 54321:54321)
chown -R 54321:54321 /export/oradata/sidb-primary /export/oradata/sidb-standby

# Set permissions
chmod 775 /export/oradata/sidb-primary /export/oradata/sidb-standby

# Verify NFS export exists
cat /etc/exports
# Should include: /export/oradata *(rw,sync,no_root_squash)

# If missing, add and restart NFS
echo '/export/oradata *(rw,sync,no_root_squash)' >> /etc/exports
exportfs -ra
systemctl restart nfs-server
```

### Step 2: Create Namespace and Secrets

```bash
# Create namespace
kubectl create namespace sidb

# Create database password secret
kubectl create secret generic db-admin-secret -n sidb \
  --from-literal=oracle_pwd='oracle'

# Create Oracle Container Registry pull secret
# IMPORTANT: Replace YOUR_EMAIL and YOUR_PASSWORD with actual credentials
kubectl create secret docker-registry oracle-container-registry-secret -n sidb \
  --docker-server=container-registry.oracle.com \
  --docker-username='YOUR_EMAIL' \
  --docker-password='YOUR_PASSWORD' \
  --docker-email='YOUR_EMAIL'
```

### Step 3: Accept Oracle Container Registry License

**CRITICAL:** Before pulling images, accept the license:

1. Go to https://container-registry.oracle.com
2. Sign in with Oracle SSO
3. Navigate to **Database** > **enterprise**
4. Click **Continue** and accept the license agreement
5. Wait 2-3 minutes for propagation

**Error if skipped:**
```
rpc error: code = Unknown desc = unable to retrieve auth token:
invalid username/password: authentication required
```

### Step 4: Apply RBAC

```bash
# Apply node RBAC (allows operator to read node info)
kubectl apply -f /root/oracle-database-operator/rbac/node-rbac.yaml

# Apply persistent volume RBAC
kubectl apply -f /root/oracle-database-operator/rbac/persistent-volume-rbac.yaml
```

### Step 5: Create Storage Class

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF
```

### Step 6: Create Persistent Volumes and Claims

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: sidb-primary-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-storage
  nfs:
    server: 192.168.137.210
    path: /export/oradata/sidb-primary
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: sidb-standby-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-storage
  nfs:
    server: 192.168.137.210
    path: /export/oradata/sidb-standby
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sidb-primary-pvc
  namespace: sidb
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-storage
  resources:
    requests:
      storage: 100Gi
  volumeName: sidb-primary-pv
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sidb-standby-pvc
  namespace: sidb
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-storage
  resources:
    requests:
      storage: 100Gi
  volumeName: sidb-standby-pv
EOF

# Verify PVs and PVCs
kubectl get pv
kubectl get pvc -n sidb
```

### Step 7: Deploy Primary Database

**IMPORTANT:** Use `enterprise:19.3.0.0` NOT `enterprise_ru:latest-19`

**Why:** The enterprise_ru image takes 30-45+ minutes for DBCA, exceeding Kubernetes probe timeouts and causing endless restarts.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: SingleInstanceDatabase
metadata:
  name: sidb-primary
  namespace: sidb
spec:
  sid: ORCL
  edition: enterprise
  createAs: primary

  security:
    secrets:
      admin:
        secretName: db-admin-secret
        secretKey: oracle_pwd
        keepSecret: true

  charset: AL32UTF8
  pdbName: ORCLPDB

  archiveLog: true
  forceLog: true
  flashBack: true

  image:
    pullFrom: container-registry.oracle.com/database/enterprise:19.3.0.0
    pullSecrets: oracle-container-registry-secret

  persistence:
    oradata:
      pvcName: sidb-primary-pvc
      accessMode: ReadWriteOnce
    setWritePermissions: true

  resources:
    requests:
      cpu: "2"
      memory: "8Gi"
    limits:
      cpu: "4"
      memory: "12Gi"

  services:
    endpoints:
      - name: nodeport
        type: NodePort
        tcp:
          enabled: true

  replicas: 1
EOF
```

### Step 8: Monitor Primary Creation (~20 minutes)

```bash
# Watch pod status
kubectl get pods -n sidb -w

# In another terminal, watch SIDB status
watch kubectl get singleinstancedatabase -n sidb

# Check logs if needed
kubectl logs -n sidb -l app=sidb-primary -f --tail=50

# Check alert log for real progress (DBCA stdout is buffered)
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-primary -o jsonpath='{.items[0].metadata.name}') -- tail -f /opt/oracle/diag/rdbms/orcl/ORCL/trace/alert_ORCL.log
```

**Wait until status shows:**
```
NAME           EDITION      STATUS    ROLE      VERSION      CONNECT STR
sidb-primary   Enterprise   Healthy   PRIMARY   19.3.0.0.0   192.168.137.x:xxxxx/ORCL
```

### Step 9: Create Data Guard Prerequisites Script

**Error if skipped:** Standby creation will fail looking for `/opt/oracle/configDataguardPrereqs.sh`

The `enterprise:19.3.0.0` image lacks this script. Create a dummy one:

```bash
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-primary -o jsonpath='{.items[0].metadata.name}') -- bash -c 'cat > /opt/oracle/configDataguardPrereqs.sh << "EOSCRIPT"
#!/bin/bash
echo "Data Guard prerequisites configuration complete"
exit 0
EOSCRIPT
chmod +x /opt/oracle/configDataguardPrereqs.sh'
```

### Step 10: Configure Data Guard Parameters on Primary

```bash
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-primary -o jsonpath='{.items[0].metadata.name}') -- sqlplus -s / as sysdba << 'EOF'
-- Add standby redo logs (one more than online redo logs)
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;

-- Enable Data Guard Broker
ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH;

-- Configure archive destinations
ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(ORCL,ORCLS)' SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=ORCL' SCOPE=BOTH;
ALTER SYSTEM SET FAL_SERVER='ORCLS' SCOPE=BOTH;
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH;
EXIT;
EOF
```

### Step 11: Deploy Standby Database

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: SingleInstanceDatabase
metadata:
  name: sidb-standby
  namespace: sidb
spec:
  sid: ORCLS
  createAs: standby

  primarySource:
    databaseRef: sidb-primary

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
    pullFrom: container-registry.oracle.com/database/enterprise:19.3.0.0
    pullSecrets: oracle-container-registry-secret

  persistence:
    oradata:
      pvcName: sidb-standby-pvc
      accessMode: ReadWriteOnce
    setWritePermissions: true

  resources:
    requests:
      cpu: "2"
      memory: "8Gi"
    limits:
      cpu: "4"
      memory: "12Gi"

  services:
    endpoints:
      - name: nodeport
        type: NodePort
        tcp:
          enabled: true

  replicas: 1
EOF
```

### Step 12: Add Prerequisites Script to Standby

Wait for standby pod to start (Running state), then:

```bash
# Wait for pod to be running
kubectl get pods -n sidb -w

# Once running, add the script
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-standby -o jsonpath='{.items[0].metadata.name}') -- bash -c 'cat > /opt/oracle/configDataguardPrereqs.sh << "EOSCRIPT"
#!/bin/bash
echo "Data Guard prerequisites configuration complete"
exit 0
EOSCRIPT
chmod +x /opt/oracle/configDataguardPrereqs.sh'
```

### Step 13: Monitor Standby Creation (~10 minutes)

```bash
# Watch status
watch kubectl get singleinstancedatabase -n sidb

# Note: Standby may show "Unhealthy" until DataGuardBroker is configured
# This is normal - proceed to next step
```

### Step 14: Deploy Data Guard Broker

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: DataguardBroker
metadata:
  name: sidb-standby-dg
  namespace: sidb
spec:
  execution:
    authWallet:
      enabled: true
    image: container-registry.oracle.com/database/enterprise:19.3.0.0
    imagePullSecrets:
      - oracle-container-registry-secret
  topology:
    defaults:
      adminSecretRef:
        secretKey: oracle_pwd
        secretName: db-admin-secret
    members:
      - dbUniqueName: ORCL
        endpoints:
          - host: sidb-primary
            name: tcp
            port: 1521
            protocol: TCP
            serviceName: ORCL
        localRef:
          apiVersion: database.oracle.com/v4
          kind: SingleInstanceDatabase
          name: sidb-primary
          namespace: sidb
        name: sidb-primary
        role: PRIMARY
      - dbUniqueName: ORCLS
        endpoints:
          - host: sidb-standby
            name: tcp
            port: 1521
            protocol: TCP
            serviceName: ORCLS
        localRef:
          apiVersion: database.oracle.com/v4
          kind: SingleInstanceDatabase
          name: sidb-standby
          namespace: sidb
        name: sidb-standby
        role: PHYSICAL_STANDBY
    sourceKind: SingleInstanceDatabase
    sourceRef:
      apiVersion: database.oracle.com/v4
      kind: SingleInstanceDatabase
      name: sidb-standby
      namespace: sidb
EOF
```

### Step 15: Wait for Broker Configuration (~5 minutes)

```bash
# Watch broker status
watch kubectl get dataguardbroker -n sidb

# Expected final state:
# NAME              PRIMARY   STANDBYS   PROTECTION MODE   STATUS    FSFO
# sidb-standby-dg   ORCL      ORCLS      MaxPerformance    Healthy   false
```

### Step 16: Verify Final Configuration

```bash
# Check all resources
kubectl get singleinstancedatabase -n sidb
kubectl get dataguardbroker -n sidb
kubectl get pods -n sidb

# Verify Data Guard configuration via DGMGRL
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-primary -o jsonpath='{.items[0].metadata.name}') -- dgmgrl / "show configuration"

# Expected output:
# Configuration - dg_config
#   Protection Mode: MaxPerformance
#   Members:
#   orcl  - Primary database
#     orcls - Physical standby database
# Fast-Start Failover:  Disabled
# Configuration Status:
# SUCCESS

# Verify database roles
kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-primary -o jsonpath='{.items[0].metadata.name}') -- sqlplus -s / as sysdba <<< "SELECT DATABASE_ROLE, OPEN_MODE FROM V\$DATABASE;"
# Should show: PRIMARY, READ WRITE

kubectl exec -n sidb $(kubectl get pod -n sidb -l app=sidb-standby -o jsonpath='{.items[0].metadata.name}') -- sqlplus -s / as sysdba <<< "SELECT DATABASE_ROLE, OPEN_MODE FROM V\$DATABASE;"
# Should show: PHYSICAL STANDBY, MOUNTED or READ ONLY WITH APPLY
```

### Step 17: Get Connect Strings

```bash
# Get NodePort services
kubectl get svc -n sidb

# Note the NodePort values for connecting externally
# Primary: <worker-ip>:<nodeport>/ORCL
# Standby: <worker-ip>:<nodeport>/ORCLS
```

---

## Implementation Notes (Lessons Learned)

### Image Selection: enterprise:19.3.0.0 vs enterprise_ru

| Image | Pros | Cons |
|-------|------|------|
| `enterprise:19.3.0.0` | Fast creation (~20 min), works with default probes | Missing configDataguardPrereqs.sh |
| `enterprise_ru:latest-19` | Latest patches, has DG script | Creation takes 30-45 min, causes probe timeouts |

**Recommendation:** Use `enterprise:19.3.0.0` and manually configure Data Guard prerequisites.

### NFS Mount Options

If you see `ORA-27054: NFS file system not mounted with correct options`:

```bash
# On NFS server, ensure exports use:
/export/oradata *(rw,sync,no_root_squash,no_wdelay)

# On clients, mount with:
mount -t nfs -o rw,bg,hard,nointr,tcp,vers=3,timeo=600,rsize=32768,wsize=32768,actimeo=0 server:/path /mount
```

### Pod Restart Loop During Database Creation

**Symptom:** Pod restarts every 15-20 minutes at 36% creation

**Cause:** Kubernetes liveness probe times out before DBCA completes

**Solution:** Use base `enterprise:19.3.0.0` image (creates faster)

### Monitor Real Progress

DBCA stdout is buffered. Check alert log for actual progress:

```bash
kubectl exec -n sidb <pod> -- tail -f /opt/oracle/diag/rdbms/orcl/ORCL/trace/alert_ORCL.log
```

### Standby Shows Unhealthy

This is **normal** until DataGuardBroker CR is applied and configures the broker. Standby becomes Healthy after broker setup completes.

---

## Summary of Final Configuration

| Component | Value |
|-----------|-------|
| Primary SID | ORCL |
| Standby SID | ORCLS |
| PDB Name | ORCLPDB |
| SYS Password | oracle |
| Image | container-registry.oracle.com/database/enterprise:19.3.0.0 |
| NFS Server | 192.168.137.210 |
| Primary Storage | /export/oradata/sidb-primary |
| Standby Storage | /export/oradata/sidb-standby |
| Protection Mode | MaxPerformance |

---

## Version History

| Date | Changes |
|------|---------|
| 2024-09-24 | Initial documentation |
| 2026-09-26 | Added complete 17-step walkthrough with all error fixes and lessons learned |
