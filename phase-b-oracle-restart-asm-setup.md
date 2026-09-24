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

## Version History

| Date | Changes |
|------|---------|
| 2024-09-24 | Initial draft - to be updated during implementation |
