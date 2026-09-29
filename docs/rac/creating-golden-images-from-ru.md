# Creating Golden Images from Oracle RAC RU Container

This document describes how to extract pre-patched Oracle software as golden image zip files from the `rac_ru` container image, eliminating the need for patching during RAC deployment.

---

## Overview

Oracle's `rac_ru:latest-19` image contains pre-patched Oracle software (19.32 RU), but due to the operator's hostPath architecture, this software is never used directly. However, we can extract it as golden images (zip files) and use those for deployment.

```
┌─────────────────────────────────────────────────────────────┐
│  rac_ru:latest-19 Container                                 │
│                                                             │
│  /u01/app/19c/grid/          ──► gridSetup.sh               │
│  (Pre-patched 19.32)             -createGoldImage           │
│                                        │                    │
│                                        ▼                    │
│                              grid_19.32_golden.zip (3GB)    │
│                                                             │
│  /u01/app/oracle/product/    ──► runInstaller               │
│  19c/dbhome_1/                   -createGoldImage           │
│  (Pre-patched 19.32)                   │                    │
│                                        ▼                    │
│                              db_19.32_golden.zip (3GB)      │
└─────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
                              Stage on NFS → Operator extracts
                              (No patching needed!)
```

---

## Prerequisites

1. **RAC RU image pulled** on at least one worker node
2. **NFS export** available for staging golden images
3. **kubectl access** to the cluster

---

## Step-by-Step Commands

### Step 1: Verify RU Image is Available

```bash
# Check which nodes have the image
ssh root@ocne-w2 "crictl images | grep rac_ru"

# Expected output:
# container-registry.oracle.com/database/rac_ru   latest-19   ddbd1016550c3   16.8GB
```

### Step 2: Check NFS Export

```bash
# On NFS server (ocne-op)
ssh root@ocne-op "showmount -e localhost"

# Expected output:
# /export/stage   192.168.137.0/24

# Check available space
ssh root@ocne-op "df -h /export/stage"

# Need at least 10GB free for both golden images
```

### Step 3: Create Pod YAML with NFS Mount

```bash
cat > /tmp/golden-pod.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: golden-creator
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: ocne-w2.lab.local   # Node with cached image
  containers:
  - name: golden-creator
    image: container-registry.oracle.com/database/rac_ru:latest-19
    command: ["sleep", "7200"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: nfs-stage
      mountPath: /stage
  volumes:
  - name: nfs-stage
    nfs:
      server: 192.168.137.210    # NFS server IP
      path: /export/stage        # NFS export path
  restartPolicy: Never
EOF
```

### Step 4: Create the Pod

```bash
# Apply the pod configuration
kubectl apply -f /tmp/golden-pod.yaml

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/golden-creator -n default --timeout=120s

# Verify pod is running
kubectl get pod golden-creator -n default
```

### Step 5: Verify NFS Mount Inside Pod

```bash
kubectl exec golden-creator -- bash -c 'df -h /stage && ls -la /stage'

# Expected output:
# Filesystem                     Size  Used Avail Use% Mounted on
# 192.168.137.210:/export/stage  150G  1.1G  149G   1% /stage
```

### Step 6: Create Grid Infrastructure Golden Image

```bash
kubectl exec golden-creator -- su - grid -c \
  '/u01/app/19c/grid/gridSetup.sh -createGoldImage -destinationLocation /stage -silent'

# Expected output:
# Launching Oracle Grid Infrastructure Setup Wizard...
# Successfully Setup Software.
# Gold Image location: /stage/grid_home_YYYY-MM-DD_HH-MM-SS.zip
```

**Time:** ~5-7 minutes
**Size:** ~3GB

### Step 7: Create Database Golden Image

```bash
kubectl exec golden-creator -- su - oracle -c \
  '/u01/app/oracle/product/19c/dbhome_1/runInstaller -createGoldImage -destinationLocation /stage -silent'

# Expected output:
# Launching Oracle Database Setup Wizard...
# Successfully Setup Software.
# Gold Image location: /stage/db_home_YYYY-MM-DD_HH-MM-SS.zip
```

**Time:** ~5-7 minutes
**Size:** ~3GB

### Step 8: Verify and Rename Golden Images

```bash
# On NFS server
ssh root@ocne-op "ls -lh /export/stage/"

# Rename to meaningful names
ssh root@ocne-op "cd /export/stage && \
  mv grid_home_*.zip grid_19.32_golden.zip && \
  mv db_home_*.zip db_19.32_golden.zip && \
  ls -lh"

# Expected output:
# -rw-r--r--. 1 oracle oinstall 3.1G Sep 29 19:36 db_19.32_golden.zip
# -rw-r--r--. 1 oracle oinstall 3.0G Sep 29 19:28 grid_19.32_golden.zip
```

### Step 9: Clean Up Pod

```bash
kubectl delete pod golden-creator -n default
```

---

## Using Golden Images in RAC Manifest

### Update RacDatabase CR

```yaml
apiVersion: database.oracle.com/v4
kind: RacDatabase
metadata:
  name: racdb
  namespace: rac
spec:
  # ... other config ...

  configParams:
    # Point to golden images
    hostSwStageLocation: "/scratch/software/stage"
    gridSwZipFile: "grid_19.32_golden.zip"    # Pre-patched golden image
    dbSwZipFile: "db_19.32_golden.zip"        # Pre-patched golden image

    # NO patching parameters needed!
    # ruPatchLocation: NOT NEEDED (already patched)
    # oPatchLocation: NOT NEEDED (already patched)
```

### Ensure NFS Mount in Worker Nodes

The `/scratch/software/stage` path must be mounted on worker nodes pointing to the NFS export:

```bash
# On each worker node
mkdir -p /scratch/software/stage
mount -t nfs 192.168.137.210:/export/stage /scratch/software/stage

# Or add to /etc/fstab for persistence
echo "192.168.137.210:/export/stage /scratch/software/stage nfs defaults 0 0" >> /etc/fstab
```

---

## Time Comparison

| Approach | Image Pull | Extraction | Patching | Configure | Total |
|----------|------------|------------|----------|-----------|-------|
| Base + RU patches | 10GB | 30 min | 60-90 min | 30 min | ~2.5 hours |
| RU image (unused) | 17GB | 30 min | - | 30 min | ~1.5 hours |
| **Golden images** | 10GB | **15 min** | **NONE** | 30 min | **~1 hour** |

Golden images are:
- **Smaller** (6GB total vs 15GB uncompressed)
- **Pre-patched** (no OPatch/RU application)
- **Faster extraction** (compressed format)

---

## Complete Command Sequence (Copy-Paste Ready)

```bash
# === STEP 1: Create pod YAML ===
cat > /tmp/golden-pod.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: golden-creator
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: ocne-w2.lab.local
  containers:
  - name: golden-creator
    image: container-registry.oracle.com/database/rac_ru:latest-19
    command: ["sleep", "7200"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: nfs-stage
      mountPath: /stage
  volumes:
  - name: nfs-stage
    nfs:
      server: 192.168.137.210
      path: /export/stage
  restartPolicy: Never
EOF

# === STEP 2: Create and wait for pod ===
kubectl apply -f /tmp/golden-pod.yaml
kubectl wait --for=condition=Ready pod/golden-creator -n default --timeout=120s

# === STEP 3: Create Grid golden image ===
kubectl exec golden-creator -- su - grid -c \
  '/u01/app/19c/grid/gridSetup.sh -createGoldImage -destinationLocation /stage -silent'

# === STEP 4: Create DB golden image ===
kubectl exec golden-creator -- su - oracle -c \
  '/u01/app/oracle/product/19c/dbhome_1/runInstaller -createGoldImage -destinationLocation /stage -silent'

# === STEP 5: Rename on NFS server ===
ssh root@192.168.137.210 "cd /export/stage && \
  mv grid_home_*.zip grid_19.32_golden.zip && \
  mv db_home_*.zip db_19.32_golden.zip && \
  ls -lh"

# === STEP 6: Clean up ===
kubectl delete pod golden-creator -n default
```

---

## Verification

### Check Golden Image Contents

```bash
# List contents of grid golden image
unzip -l /export/stage/grid_19.32_golden.zip | head -20

# Check OPatch version inside (confirms patch level)
unzip -p /export/stage/grid_19.32_golden.zip "*/OPatch/version.txt" 2>/dev/null
```

### Verify Patch Level

The golden images contain the same patch level as the source RU image:
- **Grid Infrastructure:** 19.32.0.0.0 (July 2024 RU)
- **Database:** 19.32.0.0.0 (July 2024 RU)

---

## Troubleshooting

### "Permission denied" writing to /stage

```bash
# Fix NFS export permissions
ssh root@ocne-op "chown -R 54321:54321 /export/stage && chmod 775 /export/stage"
```

### "No space left on device"

```bash
# Check NFS disk space
ssh root@ocne-op "df -h /export"

# Need at least 10GB free for both golden images
```

### Pod stuck in ContainerCreating

```bash
# Check events
kubectl describe pod golden-creator -n default

# Common issues:
# - NFS server unreachable
# - NFS export path incorrect
# - Image not cached on selected node
```

---

## Summary

By extracting golden images from the RU container:

1. **Leverage pre-patched software** that would otherwise be wasted
2. **Eliminate patching time** during deployment
3. **Reduce deployment time** by ~50%
4. **Create reusable artifacts** for future deployments

This approach works within the operator's existing architecture while getting the benefits of pre-patched software.

---

*Document Version: 1.0*
*Created: September 2026*
*Golden Images Created From: rac_ru:latest-19 (19.32.0.0.0)*
