# Phase B: Oracle Restart + ASM Setup Guide

This document provides step-by-step instructions to deploy Oracle Restart with ASM on OCNE 1.9 using the Oracle Database Operator.

**Note:** This document will be updated as we progress through the implementation.

---

## Prerequisites Completed

- OCNE 1.9 cluster with Kubernetes 1.29
- Oracle Database Operator installed in `oracle-database-operator-system` namespace
- cert-manager and Multus installed
- Phase A (SIDB + Data Guard) completed (optional, can be cleaned up)
- Shared ASM disks attached to workers:
  - `asm1.vdi` (40 GB) → `/dev/sdc`
  - `asm2.vdi` (40 GB) → `/dev/sdd`
  - `asm3.vdi` (20 GB) → `/dev/sde`
- NFS storage configured on ocne-op

---

## Architecture Overview

```
+------------------+          +------------------+
|     ocne-w1      |          |     ocne-w2      |
|                  |          |                  |
|  OracleRestart   |          |  (standby node   |
|  + ASM + DB      |          |   for Phase C)   |
|                  |          |                  |
|  /dev/sdc (ASM)  |<-------->|  /dev/sdc (ASM)  |
|  /dev/sdd (ASM)  |  shared  |  /dev/sdd (ASM)  |
|  /dev/sde (ASM)  |  disks   |  /dev/sde (ASM)  |
+------------------+          +------------------+
```

Oracle Restart provides:
- Grid Infrastructure (single instance, no cluster)
- ASM for shared storage management
- Automatic restart of database components

---

## Phase B1: Worker Preparation

### B1.1 Configure HugePages

HugePages improve Oracle SGA performance. Configure on **both workers**.

**Calculate HugePages:**
- Worker RAM: 20 GB
- HugePages allocation: ~6 GB (3072 × 2 MB pages)
- Leaves ~14 GB for OS and containers

```bash
# On both ocne-w1 and ocne-w2
cat >> /etc/sysctl.conf <<'EOF'
# HugePages for Oracle - 6GB (3072 x 2MB pages)
vm.nr_hugepages = 3072
EOF

sysctl -p

# Verify
grep -i hugepages /proc/meminfo
```

**Expected output:**
```
HugePages_Total:    3072
HugePages_Free:     3072
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB
```

### B1.2 Configure Kubelet Unsafe Sysctls

The Oracle containers require certain sysctls that kubelet blocks by default.

On **both workers**, edit `/var/lib/kubelet/kubeadm-flags.env`:

```bash
# On both ocne-w1 and ocne-w2

# Backup first
cp /var/lib/kubelet/kubeadm-flags.env /var/lib/kubelet/kubeadm-flags.env.bak.$(date +%s)

# Check current content
cat /var/lib/kubelet/kubeadm-flags.env
```

Add `--allowed-unsafe-sysctls` to the KUBELET_KUBEADM_ARGS line:

```bash
# Edit the file to add the flag
# The line should look like:
# KUBELET_KUBEADM_ARGS="... --allowed-unsafe-sysctls=kernel.msgmax,kernel.msgmnb,kernel.msgmni,kernel.shmmni,kernel.sem,net.core.rmem_default,net.core.rmem_max,net.core.wmem_default,net.core.wmem_max"

# Restart kubelet
systemctl restart kubelet
systemctl status kubelet
```

### B1.3 Install SELinux Policy Module

The RAC/Oracle Restart containers need specific SELinux permissions.

```bash
# On both workers
cd /tmp

# Create the policy module
cat > rac-ocne.te <<'EOF'
module rac-ocne 1.0;

require {
    type container_t;
    type container_file_t;
    type hugetlbfs_t;
    type sysfs_t;
    type proc_t;
    type device_t;
    type fixed_disk_device_t;
    type unlabeled_t;
    class capability { sys_resource sys_nice ipc_lock };
    class file { read write open getattr execute execute_no_trans map };
    class dir { read write open getattr search add_name remove_name };
    class blk_file { read write open getattr ioctl };
    class chr_file { read write open getattr ioctl };
    class fifo_file { read write open getattr };
    class sock_file { read write open getattr };
    class lnk_file { read getattr };
    class unix_stream_socket { connectto };
    class process { setrlimit };
}

# Allow container processes required capabilities
allow container_t self:capability { sys_resource sys_nice ipc_lock };
allow container_t self:process setrlimit;

# Allow access to hugepages
allow container_t hugetlbfs_t:file { read write open getattr map };
allow container_t hugetlbfs_t:dir { read open getattr search };

# Allow access to /sys and /proc
allow container_t sysfs_t:file { read open getattr };
allow container_t sysfs_t:dir { read open getattr search };
allow container_t proc_t:file { read open getattr };

# Allow access to block devices (ASM disks)
allow container_t device_t:blk_file { read write open getattr ioctl };
allow container_t device_t:chr_file { read write open getattr ioctl };
allow container_t fixed_disk_device_t:blk_file { read write open getattr ioctl };
allow container_t unlabeled_t:blk_file { read write open getattr ioctl };

# Allow container file operations
allow container_t container_file_t:file { read write open getattr execute execute_no_trans map };
allow container_t container_file_t:dir { read write open getattr search add_name remove_name };
allow container_t container_file_t:lnk_file { read getattr };
allow container_t container_file_t:fifo_file { read write open getattr };
allow container_t container_file_t:sock_file { read write open getattr };
EOF

# Compile and install
checkmodule -M -m -o rac-ocne.mod rac-ocne.te
semodule_package -o rac-ocne.pp -m rac-ocne.mod
semodule -i rac-ocne.pp

# Verify
semodule -l | grep rac-ocne
```

### B1.4 Configure SELinux File Contexts

```bash
# On both workers

# Set context for scratch directories
semanage fcontext -a -t container_file_t "/scratch(/.*)?"
restorecon -Rv /scratch

# Set context for Oracle data directories
semanage fcontext -a -t container_file_t "/opt/oracle(/.*)?"
mkdir -p /opt/oracle
restorecon -Rv /opt/oracle

# Verify
ls -laZ /scratch
ls -laZ /opt/oracle
```

### B1.5 Create Per-Node Directories

```bash
# On both workers

# Create directories for Oracle Restart
mkdir -p /scratch/oracle/orabase
mkdir -p /scratch/oracle/orahome
mkdir -p /scratch/oracle/oradata

# Set ownership (Oracle runs as 54321:54321)
chown -R 54321:54321 /scratch/oracle
chmod -R 775 /scratch/oracle

# Verify
ls -la /scratch/oracle
```

### B1.6 Verify ASM Disk Visibility

```bash
# On both workers

# Check disk visibility
lsblk

# Verify by-id links (set in Phase 4)
ls -l /dev/disk/by-id/ | grep asmdisk

# Expected output:
# lrwxrwxrwx. 1 root root  9 ... ata-VBOX_HARDDISK_asmdisk0001 -> ../../sdc
# lrwxrwxrwx. 1 root root  9 ... ata-VBOX_HARDDISK_asmdisk0002 -> ../../sdd
# lrwxrwxrwx. 1 root root  9 ... ata-VBOX_HARDDISK_asmdisk0003 -> ../../sde

# CRITICAL: Verify disks are clean (no partition table, no filesystem)
file -s /dev/sdc
file -s /dev/sdd
file -s /dev/sde
# Should show: "/dev/sdX: data" (not a filesystem)
```

### B1.7 Set ASM Disk Permissions

```bash
# On both workers

# Create udev rules for ASM disks
cat > /etc/udev/rules.d/99-oracle-asm.rules <<'EOF'
# ASM disk permissions for Oracle
KERNEL=="sd*", ENV{ID_SERIAL}=="*asmdisk*", OWNER="54321", GROUP="54321", MODE="0660"
EOF

# Reload udev rules
udevadm control --reload-rules
udevadm trigger

# Verify permissions
ls -l /dev/sdc /dev/sdd /dev/sde
```

### B1.8 Reboot Workers and Verify

```bash
# On both workers
reboot

# After reboot, verify everything:
# 1. HugePages
grep -i hugepages /proc/meminfo

# 2. Kubelet running
systemctl status kubelet

# 3. SELinux module loaded
semodule -l | grep rac-ocne

# 4. ASM disks visible and owned correctly
ls -l /dev/sdc /dev/sdd /dev/sde
ls -l /dev/disk/by-id/ | grep asmdisk

# 5. Directories exist with correct ownership
ls -la /scratch/oracle/
```

---

## Phase B2: Deploy Oracle Restart

### B2.1 Create Namespace (if not exists)

```bash
kubectl create namespace rac
```

### B2.2 Create Secrets

```bash
# Database password secret
kubectl create secret generic db-user-pass -n rac \
  --from-literal=oracle_pwd='oracle'

# Oracle Container Registry pull secret
kubectl create secret docker-registry oracle-container-registry-secret -n rac \
  --docker-server=container-registry.oracle.com \
  --docker-username='YOUR_EMAIL' \
  --docker-password='YOUR_PASSWORD' \
  --docker-email='YOUR_EMAIL'
```

### B2.3 Create Block-Mode PersistentVolumes

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: asm-disk1-pv
spec:
  capacity:
    storage: 40Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Block
  local:
    path: /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ocne-w1.lab.local
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: asm-disk2-pv
spec:
  capacity:
    storage: 40Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Block
  local:
    path: /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ocne-w1.lab.local
EOF
```

### B2.4 Apply RBAC for Oracle Restart

```bash
kubectl apply -f /root/oracle-database-operator/docs/rac/rbac/pv-rbac.yaml
```

### B2.5 Deploy OracleRestart CR

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: OracleRestart
metadata:
  name: oracle-restart
  namespace: rac
spec:
  # Grid Infrastructure image
  image:
    pullFrom: container-registry.oracle.com/database/rac:19.3.0-slim
    pullSecrets: oracle-container-registry-secret

  # Node selector - deploy on ocne-w1
  nodeSelector:
    kubernetes.io/hostname: ocne-w1.lab.local

  # Grid Infrastructure home
  gridHome:
    path: /u01/app/19.3.0/grid

  # Oracle base
  oracleBase: /u01/app/oracle

  # ASM configuration
  asmDevices:
    - /dev/sdc
    - /dev/sdd

  asmDiskGroups:
    - name: DATA
      redundancy: EXTERNAL
      disks:
        - /dev/sdc
        - /dev/sdd

  # Database configuration (optional, can be added later)
  # database:
  #   name: ORCL
  #   uniqueName: ORCL
  #   pdbName: ORCLPDB

  # Resources
  resources:
    requests:
      cpu: "4"
      memory: "8Gi"
    limits:
      cpu: "8"
      memory: "16Gi"

  # Persistence
  persistence:
    gridHome:
      storageClass: nfs-storage
      size: 30Gi
    oracleBase:
      storageClass: nfs-storage
      size: 30Gi
EOF
```

**Note:** The exact spec may need adjustment based on the operator version and documentation. This will be updated during implementation.

### B2.6 Monitor Deployment

```bash
# Watch pods
kubectl get pods -n rac -w

# Check OracleRestart status
kubectl get oraclerestart -n rac

# View logs
kubectl logs -n rac -l app=oracle-restart -f --tail=50

# Describe for events
kubectl describe oraclerestart oracle-restart -n rac
```

### B2.7 Verify Oracle Restart Installation

```bash
# Get pod name
RESTART_POD=$(kubectl get pod -n rac -l app=oracle-restart -o jsonpath='{.items[0].metadata.name}')

# Check Grid Infrastructure status
kubectl exec -n rac $RESTART_POD -- /u01/app/19.3.0/grid/bin/crsctl stat res -t

# Check ASM status
kubectl exec -n rac $RESTART_POD -- /u01/app/19.3.0/grid/bin/asmcmd lsdg

# Check ASM disk groups
kubectl exec -n rac $RESTART_POD -- su - oracle -c "sqlplus / as sysasm <<< 'SELECT name, state, total_mb, free_mb FROM v\\\$asm_diskgroup;'"
```

**Expected output:**
```
NAME       STATE      TOTAL_MB   FREE_MB
---------- ---------- ---------- ----------
DATA       MOUNTED        81920     81800
```

---

## Phase B3: ASM Disk Operations

### B3.1 Add a Disk to ASM

Add `asm3.vdi` (20 GB) to the DATA disk group.

```bash
# First, create PV for the third disk
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: asm-disk3-pv
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Block
  local:
    path: /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0003
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ocne-w1.lab.local
EOF

# Add disk to ASM from inside the pod
RESTART_POD=$(kubectl get pod -n rac -l app=oracle-restart -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n rac $RESTART_POD -- su - oracle -c "sqlplus / as sysasm << 'EOF'
ALTER DISKGROUP DATA ADD DISK '/dev/sde' NAME data_0003;
SELECT name, path, total_mb, free_mb FROM v\$asm_disk WHERE group_number > 0;
EOF"
```

### B3.2 Verify Disk Addition

```bash
kubectl exec -n rac $RESTART_POD -- /u01/app/19.3.0/grid/bin/asmcmd lsdg
kubectl exec -n rac $RESTART_POD -- su - oracle -c "sqlplus / as sysasm <<< 'SELECT name, path, total_mb FROM v\\\$asm_disk WHERE group_number > 0;'"
```

### B3.3 Remove a Disk from ASM

```bash
kubectl exec -n rac $RESTART_POD -- su - oracle -c "sqlplus / as sysasm << 'EOF'
ALTER DISKGROUP DATA DROP DISK data_0003;
-- Monitor rebalance
SELECT operation, state, power, est_minutes FROM v\$asm_operation;
EOF"

# Wait for rebalance to complete, then verify
kubectl exec -n rac $RESTART_POD -- su - oracle -c "sqlplus / as sysasm <<< 'SELECT name, path FROM v\\\$asm_disk WHERE group_number > 0;'"
```

---

## Troubleshooting

### Common Issues

1. **HugePages not available**
   - Check: `grep -i hugepages /proc/meminfo`
   - Fix: Ensure `vm.nr_hugepages=3072` in `/etc/sysctl.conf` and reboot

2. **Pod fails with permission denied**
   - Check: SELinux denials in `/var/log/audit/audit.log`
   - Fix: Verify `rac-ocne` module is loaded: `semodule -l | grep rac`

3. **ASM disks not visible in pod**
   - Check: `ls -l /dev/sd[cde]` on the worker
   - Check: PV/PVC status: `kubectl get pv,pvc -n rac`
   - Fix: Ensure correct udev rules and device permissions

4. **Kubelet won't start after adding unsafe sysctls**
   - Check: `journalctl -u kubelet -f`
   - Fix: Verify syntax in `/var/lib/kubelet/kubeadm-flags.env`

5. **ASM creation fails - disk not clean**
   - Fix: Wipe disk headers: `dd if=/dev/zero of=/dev/sdX bs=1M count=100`

### Useful Commands

```bash
# Check Oracle Restart pod logs
kubectl logs -n rac $(kubectl get pod -n rac -l app=oracle-restart -o jsonpath='{.items[0].metadata.name}') -f

# Check Grid Infrastructure status
kubectl exec -n rac $POD -- crsctl stat res -t

# Check ASM disk groups
kubectl exec -n rac $POD -- asmcmd lsdg

# Check ASM disks
kubectl exec -n rac $POD -- asmcmd lsdsk

# Check SELinux denials
grep AVC /var/log/audit/audit.log | tail -20

# Check kubelet status
systemctl status kubelet
journalctl -u kubelet --since "10 minutes ago"
```

---

## Cleanup

To remove Oracle Restart and start fresh:

```bash
# Delete OracleRestart CR
kubectl delete oraclerestart oracle-restart -n rac

# Wait for pod termination
kubectl get pods -n rac -w

# Delete PVs
kubectl delete pv asm-disk1-pv asm-disk2-pv asm-disk3-pv

# Clean ASM disk headers (on workers)
ssh root@ocne-w1 "dd if=/dev/zero of=/dev/sdc bs=1M count=100"
ssh root@ocne-w1 "dd if=/dev/zero of=/dev/sdd bs=1M count=100"
ssh root@ocne-w1 "dd if=/dev/zero of=/dev/sde bs=1M count=100"
```

---

## Next Steps

After completing Phase B:

1. **Phase C1**: Create Multus NetworkAttachmentDefinitions for RAC interconnect
2. **Phase C2**: Deploy two-node RacDatabase
3. **Phase C3**: Scale-out exercise

---

## Complete Implementation Walkthrough (Tested September 2026)

This section documents the exact steps that worked, including all errors encountered and their fixes.

### Step 1: Recover Cluster (if needed)

If cluster is unresponsive after VM restart:

```bash
# Check and restart services on all nodes
for node in ocne-cp1 ocne-w1 ocne-w2; do
  ssh root@$node "systemctl restart crio && systemctl restart kubelet"
done

# Verify cluster is healthy
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
```

### Step 2: Fix Operator RBAC Permissions

**Error encountered:** `storageclasses.storage.k8s.io is forbidden`

```bash
# Create ClusterRole for StorageClass access
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: oracle-database-operator-storageclass-reader
rules:
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oracle-database-operator-storageclass-reader-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: oracle-database-operator-storageclass-reader
subjects:
- kind: ServiceAccount
  name: default
  namespace: oracle-database-operator-system
EOF

# Create ClusterRole for PV/PVC access
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: oracle-database-operator-pv-manager
rules:
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oracle-database-operator-pv-manager-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: oracle-database-operator-pv-manager
subjects:
- kind: ServiceAccount
  name: default
  namespace: oracle-database-operator-system
EOF
```

### Step 3: Reduce HugePages (if memory insufficient)

**Error encountered:** `Insufficient memory` - pod requests 16Gi but only 13Gi allocatable

```bash
# On both workers - reduce HugePages from 6GB to 2GB
ssh root@ocne-w1 "echo 'vm.nr_hugepages = 1024' > /etc/sysctl.d/99-hugepages.conf && sysctl -p /etc/sysctl.d/99-hugepages.conf"
ssh root@ocne-w2 "echo 'vm.nr_hugepages = 1024' > /etc/sysctl.d/99-hugepages.conf && sysctl -p /etc/sysctl.d/99-hugepages.conf"

# Verify
ssh root@ocne-w1 "grep -i hugepages /proc/meminfo"
```

### Step 4: Add Required Sysctls to Kubelet

**Error encountered:** `SysctlForbidden` for kernel.shmmax, kernel.shmall

```bash
# On both workers - backup and update kubeadm-flags.env
for node in ocne-w1 ocne-w2; do
  ssh root@$node 'cp /var/lib/kubelet/kubeadm-flags.env /var/lib/kubelet/kubeadm-flags.env.bak'

  # Add allowed-unsafe-sysctls (append to existing KUBELET_KUBEADM_ARGS)
  ssh root@$node 'sed -i '\''s/"$/ --allowed-unsafe-sysctls=kernel.shmmax,kernel.shmall,kernel.msgmax,kernel.msgmnb,kernel.msgmni,kernel.shmmni,kernel.sem,net.core.rmem_default,net.core.rmem_max,net.core.wmem_default,net.core.wmem_max"/'\'' /var/lib/kubelet/kubeadm-flags.env'

  ssh root@$node 'systemctl restart kubelet'
done
```

### Step 5: Deploy OracleRestart CR

**CRITICAL:** Use hostname (ocne-w1.lab.local), NOT IP address (192.168.137.221)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: database.oracle.com/v4
kind: OracleRestart
metadata:
  name: orestart-sample
  namespace: rac
spec:
  instDetails:
    name: oradb1
    hostSwLocation: /scratch/orestart/
    workerNode:
      - ocne-w1.lab.local
    envVars:
      - name: IGNORE_CRS_PREREQS
        value: "true"
      - name: IGNORE_DB_PREREQS
        value: "true"
  asmDiskGroupDetails:
    - name: DATA
      redundancy: EXTERNAL
      type: CRSDG
      disks:
        - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001
        - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002
  resources:
    requests:
      memory: "16Gi"
      cpu: "4"
    limits:
      memory: "17Gi"
      cpu: "8"
  configParams:
    gridHome: "/u01/app/19c/grid"
    gridBase: "/u01/app/grid"
    dbHome: "/u01/app/oracle/product/19c/dbhome_1"
    sgaSize: "3G"
    pgaSize: "1G"
    dbName: "ORCL"
EOF

# Wait for pod to be running
kubectl get pods -n rac -w
```

### Step 6: Stage Oracle Software in Pod

Once pod is running, stage the software (if not pre-installed in image):

```bash
POD="oradb1-0"

# Copy Grid and DB software zips to pod (from NFS or local)
# These should be ~6GB each
kubectl exec -n rac $POD -- ls -la /tmp/patches/

# Extract Grid home (as grid user)
kubectl exec -n rac $POD -- su - grid -c "cd /u01/app/19c/grid && unzip -oq /tmp/patches/LINUX.X64_193000_grid_home.zip"

# Extract DB home (as oracle user)
kubectl exec -n rac $POD -- su - oracle -c "cd /u01/app/oracle/product/19c/dbhome_1 && unzip -oq /tmp/patches/LINUX.X64_193000_db_home.zip"

# Verify sizes (~6GB each)
kubectl exec -n rac $POD -- du -sh /u01/app/19c/grid
kubectl exec -n rac $POD -- du -sh /u01/app/oracle/product/19c/dbhome_1
```

### Step 7: Create glibc 2.34+ Compatibility Library

**Error encountered:** `undefined reference to 'stat'` during gridSetup.sh

```bash
POD="oradb1-0"

# Create and compile stat wrapper
kubectl exec -n rac $POD -- bash -c 'cat > /tmp/stat_wrapper.c << "EOF"
#include <sys/stat.h>
#include <sys/types.h>

int stat(const char *__restrict __file, struct stat *__restrict __buf) {
    return __xstat(1, __file, __buf);
}
int lstat(const char *__restrict __file, struct stat *__restrict __buf) {
    return __lxstat(1, __file, __buf);
}
int fstat(int __fd, struct stat *__buf) {
    return __fxstat(1, __fd, __buf);
}
EOF
gcc -c -fPIC /tmp/stat_wrapper.c -o /tmp/stat_wrapper.o
ar rcs /tmp/libstat_compat.a /tmp/stat_wrapper.o'

# Copy to both Oracle homes
kubectl exec -n rac $POD -- cp /tmp/libstat_compat.a /u01/app/19c/grid/lib/stubs/
kubectl exec -n rac $POD -- cp /tmp/libstat_compat.a /u01/app/oracle/product/19c/dbhome_1/lib/stubs/

# Update sysliblist in both homes
kubectl exec -n rac $POD -- bash -c 'echo "-ldl -lm -lpthread -lnsl -lirc -limf -lirc -lrt -laio -lresolv -lsvml -lstat_compat" > /u01/app/19c/grid/lib/sysliblist'
kubectl exec -n rac $POD -- bash -c 'echo "-ldl -lm -lpthread -lnsl -lirc -limf -lirc -lrt -laio -lresolv -lsvml -lstat_compat" > /u01/app/oracle/product/19c/dbhome_1/lib/sysliblist'
```

### Step 8: Install Grid Infrastructure

```bash
POD="oradb1-0"

# Clean any previous inventory
kubectl exec -n rac $POD -- rm -rf /u01/app/oraInventory/*

# Run gridSetup.sh (software only first)
kubectl exec -n rac $POD -- su - grid -c 'export CV_ASSUME_DISTID=OL8 && \
  /u01/app/19c/grid/gridSetup.sh -silent -ignorePreReq -waitforcompletion -noCopy \
  oracle.install.option=CRS_SWONLY \
  INVENTORY_LOCATION=/u01/app/oraInventory \
  ORACLE_HOME=/u01/app/19c/grid \
  ORACLE_BASE=/u01/app/grid \
  oracle.install.asm.OSDBA=asmdba \
  oracle.install.asm.OSOPER=asmoper \
  oracle.install.asm.OSASM=asmadmin'

# Expected: exit code 6 = "Successfully Setup Software with warning(s)"
```

### Step 9: Run Root Scripts

```bash
POD="oradb1-0"

# Run orainstRoot.sh
kubectl exec -n rac $POD -- /u01/app/oraInventory/orainstRoot.sh

# Run Grid root.sh
kubectl exec -n rac $POD -- /u01/app/19c/grid/root.sh

# Check log for success message:
# "Successfully configured Oracle Restart for a standalone server"
```

### Step 10: Configure Oracle Restart with ASM

```bash
POD="oradb1-0"

# Run Grid configuration for HA_CONFIG (Oracle Restart + ASM)
kubectl exec -n rac $POD -- su - grid -c 'export CV_ASSUME_DISTID=OL8 && \
  /u01/app/19c/grid/gridSetup.sh -silent -ignorePreReq -waitforcompletion \
  oracle.install.option=HA_CONFIG \
  INVENTORY_LOCATION=/u01/app/oraInventory \
  ORACLE_HOME=/u01/app/19c/grid \
  ORACLE_BASE=/u01/app/grid \
  oracle.install.asm.OSDBA=asmdba \
  oracle.install.asm.OSOPER=asmoper \
  oracle.install.asm.OSASM=asmadmin \
  oracle.install.asm.storageOption=ASM \
  oracle.install.asm.SYSASMPassword=Oracle_123 \
  oracle.install.asm.monitorPassword=Oracle_123 \
  oracle.install.asm.diskGroup.name=DATA \
  oracle.install.asm.diskGroup.redundancy=EXTERNAL \
  oracle.install.asm.diskGroup.disks=/dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001,/dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002 \
  oracle.install.asm.diskGroup.diskDiscoveryString=/dev/disk/by-id/ata-VBOX*'

# Run root.sh again
kubectl exec -n rac $POD -- /u01/app/19c/grid/root.sh
```

### Step 11: Configure ASM Manually (if gridSetup fails)

If ASMCA fails during config, configure manually:

```bash
POD="oradb1-0"

# Add ASM to Oracle Restart
kubectl exec -n rac $POD -- su - grid -c '/u01/app/19c/grid/bin/srvctl add asm'

# Set ASM diskstring
kubectl exec -n rac $POD -- su - grid -c '/u01/app/19c/grid/bin/srvctl modify asm -diskstring "/dev/disk/by-id/ata-VBOX*"'

# Create ASM init file
kubectl exec -n rac $POD -- bash -c 'mkdir -p /u01/app/grid/admin/+ASM/pfile && cat > /u01/app/grid/admin/+ASM/pfile/initASM.ora << "EOF"
instance_type=ASM
asm_diskstring=/dev/disk/by-id/ata-VBOX*
large_pool_size=16M
EOF
chown grid:oinstall /u01/app/grid/admin/+ASM/pfile/initASM.ora'

# Start ASM with pfile
kubectl exec -n rac $POD -- su - grid -c 'export ORACLE_SID=+ASM && export ORACLE_HOME=/u01/app/19c/grid && \
  sqlplus / as sysasm << EOF
startup pfile=/u01/app/grid/admin/+ASM/pfile/initASM.ora nomount;
EOF'

# Create disk group
kubectl exec -n rac $POD -- su - grid -c 'export ORACLE_SID=+ASM && export ORACLE_HOME=/u01/app/19c/grid && \
  sqlplus / as sysasm << EOF
CREATE DISKGROUP DATA EXTERNAL REDUNDANCY
  DISK '\''/dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001'\'',
       '\''/dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002'\''
  ATTRIBUTE '\''compatible.asm'\'' = '\''19.0.0.0.0'\'';
EOF'

# Shutdown and restart via srvctl
kubectl exec -n rac $POD -- su - grid -c 'export ORACLE_SID=+ASM && export ORACLE_HOME=/u01/app/19c/grid && \
  sqlplus / as sysasm << EOF
shutdown abort;
EOF'

kubectl exec -n rac $POD -- su - grid -c '/u01/app/19c/grid/bin/srvctl start asm'
kubectl exec -n rac $POD -- su - grid -c '/u01/app/19c/grid/bin/srvctl start diskgroup -diskgroup DATA'
```

### Step 12: Install Database Software

```bash
POD="oradb1-0"

kubectl exec -n rac $POD -- su - oracle -c 'export CV_ASSUME_DISTID=OL8 && \
  /u01/app/oracle/product/19c/dbhome_1/runInstaller -silent -ignorePrereq -waitforcompletion \
  oracle.install.option=INSTALL_DB_SWONLY \
  UNIX_GROUP_NAME=oinstall \
  INVENTORY_LOCATION=/u01/app/oraInventory \
  ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 \
  ORACLE_BASE=/u01/app/oracle \
  oracle.install.db.InstallEdition=EE \
  oracle.install.db.OSDBA_GROUP=dba \
  oracle.install.db.OSOPER_GROUP=oper \
  oracle.install.db.OSBACKUPDBA_GROUP=backupdba \
  oracle.install.db.OSDGDBA_GROUP=dgdba \
  oracle.install.db.OSKMDBA_GROUP=kmdba \
  oracle.install.db.OSRACDBA_GROUP=racdba'

# Expected: exit code 6 = success with warnings

# Run root.sh
kubectl exec -n rac $POD -- /u01/app/oracle/product/19c/dbhome_1/root.sh
```

### Step 13: Create Database Manually (DBCA fails due to /tmp noexec)

**Error encountered:** `[FATAL] [DBT-50000] Unable to check for available memory`

Create database via SQL*Plus instead:

```bash
POD="oradb1-0"

# Create admin directory
kubectl exec -n rac $POD -- bash -c 'mkdir -p /u01/app/oracle/admin/ORCL/adump && chown -R oracle:oinstall /u01/app/oracle/admin'

# Create init file
kubectl exec -n rac $POD -- bash -c 'cat > /u01/app/oracle/product/19c/dbhome_1/dbs/initORCL.ora << "EOF"
db_name=ORCL
db_unique_name=ORCL
db_block_size=8192
sga_target=3G
pga_aggregate_target=1G
processes=300
audit_file_dest=/u01/app/oracle/admin/ORCL/adump
audit_trail=DB
compatible=19.0.0
control_files=+DATA
db_recovery_file_dest=+DATA
db_recovery_file_dest_size=20G
diagnostic_dest=/u01/app/oracle
enable_pluggable_database=TRUE
open_cursors=300
remote_login_passwordfile=EXCLUSIVE
undo_tablespace=UNDOTBS1
EOF
chown oracle:oinstall /u01/app/oracle/product/19c/dbhome_1/dbs/initORCL.ora'

# Start instance nomount
kubectl exec -n rac $POD -- su - oracle -c 'export ORACLE_SID=ORCL && export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 && \
  sqlplus / as sysdba << EOF
startup nomount;
EOF'

# Create database (this takes several minutes)
kubectl exec -n rac $POD -- bash -c 'cat > /tmp/create_db.sql << "EOSQL"
CREATE DATABASE ORCL
  USER SYS IDENTIFIED BY Oracle_123
  USER SYSTEM IDENTIFIED BY Oracle_123
  LOGFILE GROUP 1 ('\''+'DATA'\'') SIZE 200M,
          GROUP 2 ('\''+'DATA'\'') SIZE 200M,
          GROUP 3 ('\''+'DATA'\'') SIZE 200M
  MAXLOGFILES 5
  MAXLOGMEMBERS 5
  MAXLOGHISTORY 1
  MAXDATAFILES 100
  MAXINSTANCES 1
  CHARACTER SET AL32UTF8
  NATIONAL CHARACTER SET AL16UTF16
  DATAFILE '\''+'DATA'\'' SIZE 1G AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED
  SYSAUX DATAFILE '\''+'DATA'\'' SIZE 500M AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED
  DEFAULT TABLESPACE users DATAFILE '\''+'DATA'\'' SIZE 500M AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED
  DEFAULT TEMPORARY TABLESPACE temp TEMPFILE '\''+'DATA'\'' SIZE 200M AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED
  UNDO TABLESPACE undotbs1 DATAFILE '\''+'DATA'\'' SIZE 500M AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED
  ENABLE PLUGGABLE DATABASE
    SEED FILE_NAME_CONVERT = ('\''+'DATA'\'', '\''+'DATA'\'');
exit;
EOSQL
chown oracle:oinstall /tmp/create_db.sql'

kubectl exec -n rac $POD -- su - oracle -c 'export ORACLE_SID=ORCL && export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 && \
  sqlplus / as sysdba @/tmp/create_db.sql'
```

### Step 14: Run Catalog Scripts

```bash
POD="oradb1-0"

# Run catalog.sql (takes ~2 minutes)
kubectl exec -n rac $POD -- su - oracle -c 'export ORACLE_SID=ORCL && export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 && \
  sqlplus / as sysdba @?/rdbms/admin/catalog.sql'

# Run catproc.sql (takes ~20 minutes)
kubectl exec -n rac $POD -- su - oracle -c 'export ORACLE_SID=ORCL && export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 && \
  sqlplus / as sysdba @?/rdbms/admin/catproc.sql'
```

### Step 15: Fix Control File Path and Create Spfile

**Error encountered:** `ORA-00205: error in identifying control file`

```bash
POD="oradb1-0"

# Find actual control file path in ASM
kubectl exec -n rac $POD -- su - grid -c 'export ORACLE_HOME=/u01/app/19c/grid && \
  asmcmd ls -l +DATA/ORCL/CONTROLFILE/'

# Note the control file name (e.g., Current.256.1244941015)

# Update init file with actual control file path
kubectl exec -n rac $POD -- bash -c 'cat > /u01/app/oracle/product/19c/dbhome_1/dbs/initORCL.ora << "EOF"
db_name=ORCL
db_unique_name=ORCL
db_block_size=8192
sga_target=3G
pga_aggregate_target=1G
processes=300
audit_file_dest=/u01/app/oracle/admin/ORCL/adump
audit_trail=DB
compatible=19.0.0
control_files=+DATA/ORCL/CONTROLFILE/Current.256.1244941015
db_recovery_file_dest=+DATA
db_recovery_file_dest_size=20G
diagnostic_dest=/u01/app/oracle
enable_pluggable_database=TRUE
open_cursors=300
remote_login_passwordfile=EXCLUSIVE
undo_tablespace=UNDOTBS1
EOF
chown oracle:oinstall /u01/app/oracle/product/19c/dbhome_1/dbs/initORCL.ora'

# Restart with updated pfile
kubectl exec -n rac $POD -- su - oracle -c 'export ORACLE_SID=ORCL && export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 && \
  sqlplus / as sysdba << EOF
shutdown abort;
startup pfile=/u01/app/oracle/product/19c/dbhome_1/dbs/initORCL.ora;
EOF'

# Create spfile in ASM
kubectl exec -n rac $POD -- bash -c 'cat > /tmp/create_spfile.sql << "EOF"
CREATE SPFILE='\''+DATA/ORCL/spfileORCL.ora'\'' FROM PFILE;
exit;
EOF
chown oracle:oinstall /tmp/create_spfile.sql'

kubectl exec -n rac $POD -- su - oracle -c 'export ORACLE_SID=ORCL && export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 && \
  sqlplus / as sysdba @/tmp/create_spfile.sql'

# Create spfile pointer in dbs
kubectl exec -n rac $POD -- bash -c 'echo "spfile=+DATA/ORCL/spfileORCL.ora" > /u01/app/oracle/product/19c/dbhome_1/dbs/initORCL.ora && \
  chown oracle:oinstall /u01/app/oracle/product/19c/dbhome_1/dbs/initORCL.ora'
```

### Step 16: Create PDB

```bash
POD="oradb1-0"

# Create PDB using CREATE_FILE_DEST (simpler than FILE_NAME_CONVERT)
kubectl exec -n rac $POD -- bash -c 'cat > /tmp/create_pdb.sql << "EOF"
CREATE PLUGGABLE DATABASE ORCLPDB ADMIN USER pdbadmin IDENTIFIED BY Oracle_123
  CREATE_FILE_DEST = '\''+DATA'\'';
ALTER PLUGGABLE DATABASE ORCLPDB OPEN;
ALTER PLUGGABLE DATABASE ORCLPDB SAVE STATE;
SELECT NAME, OPEN_MODE FROM V$PDBS;
exit;
EOF
chown oracle:oinstall /tmp/create_pdb.sql'

kubectl exec -n rac $POD -- su - oracle -c 'export ORACLE_SID=ORCL && export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 && \
  sqlplus / as sysdba @/tmp/create_pdb.sql'
```

### Step 17: Register Database with Oracle Restart

```bash
POD="oradb1-0"

# Add oratab entry
kubectl exec -n rac $POD -- bash -c 'echo "ORCL:/u01/app/oracle/product/19c/dbhome_1:Y" >> /etc/oratab'

# Register database with srvctl
kubectl exec -n rac $POD -- su - oracle -c '/u01/app/19c/grid/bin/srvctl add database -db ORCL \
  -oraclehome /u01/app/oracle/product/19c/dbhome_1 \
  -spfile +DATA/ORCL/spfileORCL.ora \
  -diskgroup DATA'

# Start database via srvctl
kubectl exec -n rac $POD -- su - oracle -c '/u01/app/19c/grid/bin/srvctl start database -db ORCL'
```

### Step 18: Verify Final Status

```bash
POD="oradb1-0"

# Check Oracle Restart resources
kubectl exec -n rac $POD -- su - grid -c '/u01/app/19c/grid/bin/crsctl status resource -t'

# Expected output:
# ora.DATA.dg      ONLINE  ONLINE
# ora.LISTENER.lsnr ONLINE  ONLINE
# ora.asm          ONLINE  ONLINE
# ora.orcl.db      ONLINE  ONLINE

# Check database status
kubectl exec -n rac $POD -- bash -c 'cat > /tmp/check_status.sql << "EOF"
SELECT STATUS, INSTANCE_NAME, DATABASE_STATUS FROM V$INSTANCE;
SELECT CDB, NAME, OPEN_MODE FROM V$DATABASE;
SELECT NAME, OPEN_MODE FROM V$PDBS;
exit;
EOF'

kubectl exec -n rac $POD -- su - oracle -c 'export ORACLE_SID=ORCL && export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 && \
  sqlplus / as sysdba @/tmp/check_status.sql'

# Expected:
# STATUS=OPEN, DATABASE_STATUS=ACTIVE
# CDB=YES, OPEN_MODE=READ WRITE
# PDB$SEED=READ ONLY, ORCLPDB=READ WRITE
```

### Summary of Final Configuration

| Component | Value |
|-----------|-------|
| Grid Home | /u01/app/19c/grid |
| Grid Base | /u01/app/grid |
| DB Home | /u01/app/oracle/product/19c/dbhome_1 |
| Oracle Base | /u01/app/oracle |
| ASM Diskgroup | +DATA (EXTERNAL, ~80GB) |
| CDB Name | ORCL |
| PDB Name | ORCLPDB |
| SYS Password | Oracle_123 |
| SYSASM Password | Oracle_123 |
| PDB Admin | pdbadmin / Oracle_123 |

---

## Implementation Notes (Lessons Learned)

### CRITICAL: Apply RU Patches During Installation

Oracle 19.3.0 base has compatibility issues with Oracle Linux 9 (glibc 2.34+). **Always apply the latest RU patch** during installation:

```bash
# Download latest RU patch (e.g., p39467003 for 19.23)
# Place in /tmp/patches/39467003

# Grid Infrastructure - use -applyRU
su - grid -c 'export CV_ASSUME_DISTID=OL8 && \
  /u01/app/19c/grid/gridSetup.sh -silent -ignorePreReq \
  -applyRU /tmp/patches/39467003 \
  oracle.install.option=HA_CONFIG \
  ... other options ...'

# Database - use -applyRU
su - oracle -c 'export CV_ASSUME_DISTID=OL8 && \
  /u01/app/oracle/product/19c/dbhome_1/runInstaller -silent -ignorePrereq \
  -applyRU /tmp/patches/39467003 \
  oracle.install.option=INSTALL_DB_SWONLY \
  ... other options ...'
```

### Workaround if RU Not Applied (glibc 2.34+ compatibility)

If you cannot use -applyRU, create a compatibility library for the `stat()` symbol change:

```bash
# Create stat wrapper source
cat > /tmp/stat_wrapper.c << 'EOF'
#include <sys/stat.h>
#include <sys/types.h>

int stat(const char *__restrict __file, struct stat *__restrict __buf) {
    return __xstat(1, __file, __buf);
}
int lstat(const char *__restrict __file, struct stat *__restrict __buf) {
    return __lxstat(1, __file, __buf);
}
int fstat(int __fd, struct stat *__buf) {
    return __fxstat(1, __fd, __buf);
}
EOF

# Compile and install
gcc -c -fPIC /tmp/stat_wrapper.c -o /tmp/stat_wrapper.o
ar rcs /tmp/libstat_compat.a /tmp/stat_wrapper.o

# Copy to Oracle homes
cp /tmp/libstat_compat.a /u01/app/19c/grid/lib/stubs/
cp /tmp/libstat_compat.a /u01/app/oracle/product/19c/dbhome_1/lib/stubs/

# Add to sysliblist in BOTH homes
echo "-ldl -lm -lpthread -lnsl -lirc -limf -lirc -lrt -laio -lresolv -lsvml -lstat_compat" > /u01/app/19c/grid/lib/sysliblist
echo "-ldl -lm -lpthread -lnsl -lirc -limf -lirc -lrt -laio -lresolv -lsvml -lstat_compat" > /u01/app/oracle/product/19c/dbhome_1/lib/sysliblist
```

### CV_ASSUME_DISTID Environment Variable

Always set this for Oracle 19c on OL9:
```bash
export CV_ASSUME_DISTID=OL8
```

### /tmp noexec Issue with DBCA

Container /tmp is often mounted with `noexec`, causing DBCA CVU checks to fail:
```
[FATAL] [DBT-50000] Unable to check for available memory.
```

**Workaround**: Create database manually using SQL*Plus instead of DBCA (see manual DB creation steps in this document).

### HugePages Sizing for Pod Memory Limits

If OracleRestart CR requests 16Gi memory but workers only have 13Gi allocatable (due to HugePages), reduce HugePages:

```bash
# Reduce from 3072 (6GB) to 1024 (2GB)
echo 'vm.nr_hugepages = 1024' > /etc/sysctl.d/99-hugepages.conf
sysctl -p /etc/sysctl.d/99-hugepages.conf
```

### Required Unsafe Sysctls

Must include `kernel.shmmax` and `kernel.shmall` in kubelet allowed sysctls:

```bash
# In /var/lib/kubelet/kubeadm-flags.env add:
--allowed-unsafe-sysctls=kernel.shmmax,kernel.shmall,kernel.msgmax,kernel.msgmnb,kernel.msgmni,kernel.shmmni,kernel.sem,net.core.rmem_default,net.core.rmem_max,net.core.wmem_default,net.core.wmem_max
```

### Working OracleRestart CR Spec

The actual working spec used hostnames (not IPs) for worker nodes:

```yaml
apiVersion: database.oracle.com/v4
kind: OracleRestart
metadata:
  name: orestart-sample
  namespace: rac
spec:
  instDetails:
    name: oradb1
    hostSwLocation: /scratch/orestart/
    workerNode:
      - ocne-w1.lab.local   # Use hostname, NOT IP
    envVars:
      - name: IGNORE_CRS_PREREQS
        value: "true"
      - name: IGNORE_DB_PREREQS
        value: "true"
  asmDiskGroupDetails:
    - name: DATA
      redundancy: EXTERNAL
      type: CRSDG
      disks:
        - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001
        - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002
  resources:
    requests:
      memory: "16Gi"
      cpu: "4"
    limits:
      memory: "17Gi"
      cpu: "8"
  configParams:
    gridHome: "/u01/app/19c/grid"
    gridBase: "/u01/app/grid"
    dbHome: "/u01/app/oracle/product/19c/dbhome_1"
    sgaSize: "3G"
    pgaSize: "1G"
    dbName: "ORCL"
```

### ASM Disk Discovery String

Set ASM_DISKSTRING before creating disk groups:

```bash
# In ASM init file or via srvctl
asm_diskstring=/dev/disk/by-id/ata-VBOX*

# Or via srvctl
srvctl modify asm -diskstring "/dev/disk/by-id/ata-VBOX*"
```

### Manual Database Creation (when DBCA fails)

If DBCA fails due to /tmp noexec, create database manually:

```bash
# 1. Create init file with control_files pointing to ASM
# 2. Start nomount: startup nomount pfile=...
# 3. CREATE DATABASE ... ENABLE PLUGGABLE DATABASE ...
# 4. Run @?/rdbms/admin/catalog.sql
# 5. Run @?/rdbms/admin/catproc.sql
# 6. CREATE PLUGGABLE DATABASE ... CREATE_FILE_DEST='+DATA'
# 7. Create spfile in ASM
# 8. Register with srvctl: srvctl add database -db ORCL ...
```

---

## Version History

| Date | Changes |
|------|---------|
| 2024-09-24 | Initial draft - to be updated during implementation |
| 2026-09-26 | Added implementation notes: -applyRU, glibc workaround, /tmp noexec, working CR spec |
| 2026-09-26 | Added complete 18-step walkthrough with all commands and error fixes |
