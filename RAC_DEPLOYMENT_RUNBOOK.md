# Oracle RAC 19c Deployment on OCNE 1.9 Kubernetes

## Complete Deployment Runbook with Troubleshooting

**Date:** September 26-27, 2026
**Environment:** Oracle Cloud Native Environment 1.9 on VirtualBox
**Oracle Version:** 19c with 19.32 Release Update (RU)
**Deployment Method:** Oracle Database Operator v4 with RacDatabase Custom Resource

---

## Table of Contents

1. [Environment Overview](#1-environment-overview)
2. [Prerequisites](#2-prerequisites)
3. [Pre-Deployment Setup](#3-pre-deployment-setup)
4. [RAC Deployment Phases](#4-rac-deployment-phases)
5. [Issues Encountered and Solutions](#5-issues-encountered-and-solutions)
6. [Verification Steps](#6-verification-steps)
7. [Final State](#7-final-state)
8. [Appendix](#8-appendix)

---

## 1. Environment Overview

### 1.1 Infrastructure

| Component | Details |
|-----------|---------|
| Hypervisor | VirtualBox on Windows |
| Host OS | Windows (MINGW64_NT-10.0) |
| Guest OS | Oracle Linux 9.8 with UEK |
| Kubernetes | OCNE 1.9 with Kubernetes 1.29 |
| Container Runtime | CRI-O |

### 1.2 Virtual Machines

| VM Name | Role | IP Address | Resources |
|---------|------|------------|-----------|
| ocne-op | Operator Node / NFS Server | 192.168.137.210 | 4 CPU, 8GB RAM |
| ocne-cp1 | Control Plane | 192.168.137.211 | 4 CPU, 8GB RAM |
| ocne-w1 | Worker Node 1 (RAC Node 1) | 192.168.137.212 | 6 CPU, 20GB RAM |
| ocne-w2 | Worker Node 2 (RAC Node 2) | 192.168.137.213 | 6 CPU, 20GB RAM |

### 1.3 Storage Configuration

| Disk | Purpose | Size | Shared |
|------|---------|------|--------|
| /dev/sda | OS | 60GB | No |
| /dev/sdb | /scratch (LVM) | 50GB | No |
| /dev/sdc | ASM Disk 1 | 20GB | Yes (Shareable) |
| /dev/sdd | ASM Disk 2 | 20GB | Yes (Shareable) |

### 1.4 Network Configuration

| Network | Interface | Purpose | CIDR |
|---------|-----------|---------|------|
| NAT Network | enp0s3 | External Access | 10.0.2.0/24 |
| Host-Only | enp0s8 | Private Interconnect 1 | 192.168.137.0/24 |
| Internal | enp0s9 | Private Interconnect 2 | 192.168.10.0/24 |
| Pod Network | eth0 | Kubernetes Pod Network | 10.244.0.0/16 |

---

## 2. Prerequisites

### 2.1 Software Requirements

#### On NFS Server (ocne-op)
```
/export/stage/
├── LINUX.X64_193000_grid_home.zip      # Grid Infrastructure 19.3 base
├── LINUX.X64_193000_db_home.zip        # Database 19.3 base
├── p6880880_190000_Linux-x86-64.zip    # OPatch update
└── 19c/19.29/
    ├── OPATCH/                          # Updated OPatch binaries
    └── RU/39467003/                     # 19.29 Release Update patches
```

#### Oracle Container Registry Access
- Account at container-registry.oracle.com
- Pull secret configured for `oracle-container-registry-secret`
- Image: `container-registry.oracle.com/database/rac_ru:latest-19`

### 2.2 Kubernetes Prerequisites

```bash
# Namespaces
kubectl create namespace rac

# Node Labels (on worker nodes)
kubectl label node ocne-w1.lab.local raccluster=raccluster01
kubectl label node ocne-w2.lab.local raccluster=raccluster01

# Oracle Database Operator installed
kubectl get pods -n oracle-database-operator-system
```

### 2.3 Network Prerequisites

#### Macvlan Networks (configured via Multus CNI)
```yaml
# Private network 1 (rac-priv1)
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rac-priv1
  namespace: rac
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "enp0s8",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "192.168.10.0/24"
      }
    }
```

### 2.4 Secrets Configuration

#### SSH Key Secret
```bash
# Generate SSH keys
ssh-keygen -t rsa -b 4096 -f ssh_key -N ""

# Create secret
kubectl create secret generic ssh-key-secret \
  --from-file=ssh-privkey=ssh_key \
  --from-file=ssh-pubkey=ssh_key.pub \
  -n rac
```

#### Database Password Secret (pkeyutl encryption)
```bash
# Generate RSA key
openssl genrsa -out key.pem 2048

# Encrypt password
echo -n "oracle" | openssl pkeyutl -encrypt \
  -pubin -inkey <(openssl rsa -in key.pem -pubout) \
  -pkeyopt rsa_padding_mode:oaep \
  -pkeyopt rsa_oaep_md:sha256 \
  -pkeyopt rsa_mgf1_md:sha256 \
  -out pwdfile.enc

# Create secret
kubectl create secret generic db-user-pass-pkutl \
  --from-file=key.pem \
  --from-file=pwdfile.enc \
  -n rac
```

---

## 3. Pre-Deployment Setup

### 3.1 Enable Promiscuous Mode on Host Interfaces

**CRITICAL:** Macvlan networking requires promiscuous mode on the parent interfaces.

```bash
# On both worker nodes (ocne-w1 and ocne-w2)
ip link set enp0s8 promisc on
ip link set enp0s9 promisc on

# Make persistent via /etc/rc.local
cat > /etc/rc.local << 'EOF'
#!/bin/bash
ip link set enp0s8 promisc on
ip link set enp0s9 promisc on
exit 0
EOF
chmod +x /etc/rc.local
```

### 3.2 NFS Exports Configuration

```bash
# On ocne-op (NFS server)
cat >> /etc/exports << 'EOF'
/export/stage *(rw,sync,no_root_squash,no_subtree_check)
EOF

exportfs -ra
```

### 3.3 ASM Disk Preparation

**WARNING:** Do NOT partition or format the shared ASM disks!

```bash
# On worker nodes - verify disk visibility
ls -l /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk*

# Expected output:
# ata-VBOX_HARDDISK_asmdisk0001 -> ../../sdc
# ata-VBOX_HARDDISK_asmdisk0002 -> ../../sdd
```

---

## 4. RAC Deployment Phases

### 4.1 RacDatabase Custom Resource

```yaml
# racdb.yaml
---
apiVersion: database.oracle.com/v4
kind: RacDatabase
metadata:
  name: racdb01
  namespace: rac
spec:
  instanceDetails:
    nodeCount: 2
    racHostSwLocation: /scratch/rac/cluster01
    racNodeName: racnode

    baseOnsTargetPort: 30200
    baseLsnrTargetPort: 31522

    privateIPDetails:
      - name: rac-priv1
        interface: ens1
      - name: rac-priv2
        interface: ens2

    workerNodeSelector:
      raccluster: raccluster01

  envVars:
    - name: LOG_DIR
      value: "/tmp/orod"
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

  sshKeySecret:
    name: ssh-key-secret
    privKeySecretName: ssh-privkey
    pubKeySecretName: ssh-pubkey

  dbSecret:
    name: db-user-pass-pkutl
    keyFileName: key.pem
    pwdFileName: pwdfile.enc
    encryptionType: pkeyutl
    pkeyopt: rsa_padding_mode:oaep;rsa_oaep_md:sha256;rsa_mgf1_md:sha256

  image: container-registry.oracle.com/database/rac_ru:latest-19
  imagePullPolicy: IfNotPresent
  imagePullSecret: oracle-container-registry-secret

  scanSvcName: racnode-scan
  scanSvcTargetPort: 31521

  serviceDetails:
    name: racpdb

  resources:
    requests:
      memory: "16Gi"
      cpu: "4"
    limits:
      memory: "18Gi"
      cpu: "6"

  securityContext:
    sysctls:
      - name: kernel.shmall
        value: "4194304"
      - name: kernel.sem
        value: "250 32000 100 128"
      - name: kernel.shmmax
        value: "17179869184"
      - name: kernel.shmmni
        value: "4096"
      - name: net.ipv4.conf.all.rp_filter
        value: "2"

  configParams:
    gridHome: "/u01/app/19c/grid"
    gridBase: "/u01/app/grid"
    dbHome: "/u01/app/oracle/product/19c/dbhome_1"
    dbBase: "/u01/app/oracle"
    inventory: "/u01/app/oraInventory"
    sgaSize: "8G"
    pgaSize: "2G"
    processes: 1000
    cpuCount: 4
    dbName: "RACDB"
    pdbName: "RACPDB"
    dbCharSet: "AL32UTF8"
    hostSwStageLocation: "/scratch/software/stage"
    gridSwZipFile: "LINUX.X64_193000_grid_home.zip"
    dbSwZipFile: "LINUX.X64_193000_db_home.zip"
    oPatchSwZipFile: "p6880880_190000_Linux-x86-64.zip"
    ruPatchLocation: "/scratch/software/stage/19c/19.29/RU/39467003"
    oPatchLocation: "/scratch/software/stage/19c/19.29/OPATCH"
```

### 4.2 Deploy RAC

```bash
kubectl apply -f racdb.yaml
```

### 4.3 Deployment Phases (Automated by Operator)

The Oracle Database Operator automates the following phases:

1. **Pod Creation** - Creates racnode1-0 and racnode2-0 pods
2. **Software Extraction** - Extracts Grid and DB software from NFS
3. **OPatch Update** - Updates OPatch to latest version
4. **Grid Infrastructure Installation** - Runs gridSetup.sh
5. **RU Patch Application** - Applies Release Update patches
6. **root.sh Execution** - Runs root.sh on both nodes
7. **Grid Configuration Tools** - Runs executeConfigTools
8. **Database Software Installation** - Installs DB home
9. **Database Patching** - Applies DB patches via opatchauto
10. **Database Creation** - Runs dbca to create RAC database
11. **PDB Creation** - Creates pluggable database
12. **Post-Configuration** - Runs datapatch, configures services

---

## 5. Issues Encountered and Solutions

### 5.1 Private Network Connectivity Failure (Macvlan)

**Symptom:**
```
Pods cannot ping each other on private networks (192.168.10.x, 192.168.11.x)
CVU checks fail with network connectivity errors
```

**Root Cause:**
Macvlan requires promiscuous mode on the parent interface to allow traffic between containers on the same host and across hosts.

**Solution:**
```bash
# On both worker nodes
ip link set enp0s8 promisc on
ip link set enp0s9 promisc on

# Make persistent
echo -e '#!/bin/bash\nip link set enp0s8 promisc on\nip link set enp0s9 promisc on\nexit 0' > /etc/rc.local
chmod +x /etc/rc.local
```

### 5.2 VIP Hostname Resolution Failure (PRKC-1168)

**Symptom:**
```
PRKC-1168: Unable to resolve the VIP name "racnode2-0-vip"
srvctl add vip fails
```

**Root Cause:**
VIP hostname couldn't be resolved via DNS during Grid setup.

**Solution:**
Manually add VIP using IP address:
```bash
srvctl add vip -n racnode2-0 -k 1 -A 10.244.2.53/255.255.0.0/eth0
```

### 5.3 Database Home Path Mismatch (19.0.0 vs 19c)

**Symptom:**
```
/u01/app/oracle/product/19.0.0/dbhome_1/install/utl/rootmacro.sh: No such file or directory
```

**Root Cause:**
Oracle scripts reference `19.0.0` but actual installation uses `19c` directory name.

**Solution:**
Create symbolic link:
```bash
ln -s /u01/app/oracle/product/19c/dbhome_1 /u01/app/oracle/product/19.0.0/dbhome_1
```

### 5.4 Database Home Not Installed on Node 2

**Symptom:**
```
[FATAL] [DBT-14505] Oracle RAC software is not present on nodes ([racnode2-0])
/u01/app/oracle/product/19c/dbhome_1/bin/oracle is 0 bytes
```

**Root Cause:**
The `-noCopy` flag was used during installation, preventing file distribution to node2.

**Solution:**
Copy database home from node1 to node2 using rsync:
```bash
# As oracle user on node1
rsync -avz /u01/app/oracle/product/19c/dbhome_1/ racnode2-0:/u01/app/oracle/product/19c/dbhome_1/

# Run root.sh on node2
/u01/app/oracle/product/19c/dbhome_1/root.sh

# Attach home to inventory on node2
/u01/app/oracle/product/19c/dbhome_1/oui/bin/attachHome.sh -silent \
  -invPtrLoc /u01/app/oraInventory/oraInst.loc \
  ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1 \
  ORACLE_HOME_NAME=OraDB19Home1
```

### 5.5 SSH Strict Host Key Checking Failure

**Symptom:**
```
[INS-06006] Passwordless SSH connectivity not set up
No ED25519 host key is known for racnode2-0 and you have requested strict checking.
PRVF-4009 : User equivalence is not set for nodes: racnode2-0
```

**Root Cause:**
1. SSH config had `UserKnownHostsFile /dev/null` which ignored known_hosts
2. CVU uses `-o StrictHostKeyChecking=yes` which requires keys in known_hosts

**Solution:**
```bash
# Fix SSH config (remove UserKnownHostsFile /dev/null)
cat > ~/.ssh/config << 'EOF'
Host *
    StrictHostKeyChecking no
EOF

# Add host keys to known_hosts on both nodes for both users
ssh-keyscan -t ed25519,rsa,ecdsa racnode1-0 racnode2-0 > ~/.ssh/known_hosts
chmod 644 ~/.ssh/known_hosts

# Do this for both oracle and grid users on both nodes
```

### 5.6 DNS Resolution Failure for FQDN

**Symptom:**
```
PRVG-5820 : Failed to retrieve IP address of host "racnode1-0"
PRVG-2045 : Operating system function "getaddrinfo" failed
Resource temporarily unavailable
```

**Root Cause:**
RAC pods use macvlan networking which bypasses Kubernetes service network, so they cannot reach CoreDNS (10.96.0.10).

**Solution:**
Add static entries to /etc/hosts on both pods:
```bash
# On racnode1-0
echo "10.244.2.53 racnode2-0.rac.svc.cluster.local racnode2-0-vip" >> /etc/hosts
echo "10.244.1.222 racnode1-0.rac.svc.cluster.local racnode1-0-vip" >> /etc/hosts

# On racnode2-0
echo "10.244.1.222 racnode1-0.rac.svc.cluster.local racnode1-0-vip" >> /etc/hosts
echo "10.244.2.53 racnode2-0.rac.svc.cluster.local racnode2-0-vip" >> /etc/hosts
```

### 5.7 /u01 Filesystem Full

**Symptom:**
```
/dev/mapper/vg_data-lv_scratch  50G   50G   32K 100% /u01
```

**Root Cause:**
50GB allocated for /scratch was insufficient for Grid + DB homes with patches.

**Solution:**
- Use pre-built RU image instead of applying patches separately
- Or increase /scratch LV size before deployment:
```bash
lvextend -L +20G /dev/vg_data/lv_scratch
xfs_growfs /u01
```

### 5.8 Setup Script State Recovery

**Symptom:**
Setup script fails and statefile shows "failed", preventing retry.

**Solution:**
Reset statefile to continue:
```bash
echo "pending" > /tmp/orod/.statefile
python3 /opt/scripts/startup/scripts/main.py > /tmp/orod/resume_setup.log 2>&1
```

---

## 6. Verification Steps

### 6.1 Verify Cluster Status

```bash
# Check CRS status
crsctl check cluster -all

# Expected output:
# CRS-4537: Cluster Ready Services is online
# CRS-4529: Cluster Synchronization Services is online
# CRS-4533: Event Manager is online
```

### 6.2 Verify All CRS Resources

```bash
crsctl status res -t

# All resources should show ONLINE/STABLE
```

### 6.3 Verify ASM

```bash
# Check ASM instances
srvctl status asm

# Check disk groups
asmcmd lsdg
```

### 6.4 Verify Database

```bash
# Check database status
srvctl status database -d RACDB

# Expected:
# Instance RACDB1 is running on node racnode1-0
# Instance RACDB2 is running on node racnode2-0

# Check PDB status
sqlplus / as sysdba
SQL> show pdbs

# Expected:
#     CON_ID CON_NAME     OPEN MODE  RESTRICTED
# ---------- ------------ ---------- ----------
#          2 PDB$SEED     READ ONLY  NO
#          3 ORCLPDB      READ WRITE NO
```

### 6.5 Verify Patches

```bash
# Check Grid Infrastructure patches
$GRID_HOME/OPatch/opatch lspatches

# Check Database patches
$ORACLE_HOME/OPatch/opatch lspatches

# Expected patches:
# 39526364;OCW RELEASE UPDATE 19.32.0.0.0
# 39472050;Database Release Update : 19.32.0.0.260721
```

### 6.6 Verify Listeners

```bash
# Check listener status
srvctl status listener

# Check SCAN listeners
srvctl status scan_listener

# Verify connectivity
tnsping RACDB
tnsping ORCLPDB
```

---

## 7. Final State

### 7.1 Deployment Summary

| Component | Status | Details |
|-----------|--------|---------|
| Grid Infrastructure | Running | 19c with 19.32 RU |
| ASM | Online | DATA disk group (EXTERNAL redundancy) |
| Database | Running | RACDB (2 instances) |
| Instance 1 | Online | RACDB1 on racnode1-0 |
| Instance 2 | Online | RACDB2 on racnode2-0 |
| PDB | Open | ORCLPDB (READ WRITE) |
| Patches | Applied | 19.32 RU (39526364, 39472050) |

### 7.2 Connection Information

```
# Easy Connect
sqlplus sys/oracle@racnode-scan:1521/RACDB as sysdba
sqlplus sys/oracle@racnode-scan:1521/ORCLPDB as sysdba

# TNS Names
RACDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = racnode-scan)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = RACDB)
    )
  )

ORCLPDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = racnode-scan)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ORCLPDB)
    )
  )
```

### 7.3 Total Deployment Time

| Phase | Duration |
|-------|----------|
| Pod Creation | ~5 minutes |
| Software Extraction | ~15 minutes |
| Grid Installation + Patching | ~45 minutes |
| root.sh Execution | ~20 minutes |
| Database Installation | ~30 minutes |
| Database Creation (dbca) | ~40 minutes |
| **Total** | **~2.5-3 hours** |

---

## 8. Appendix

### 8.1 Useful Commands

```bash
# Monitor setup progress
tail -f /tmp/orod/*.log

# Check pod logs
kubectl logs -f racnode1-0 -n rac -c racnode1-0

# Access pod shell
kubectl exec -it racnode1-0 -n rac -c racnode1-0 -- bash

# Check CRS alert log
tail -f $GRID_HOME/diag/crs/$(hostname)/crs/trace/alert*.log

# Check database alert log
tail -f $ORACLE_BASE/diag/rdbms/racdb/RACDB1/trace/alert_RACDB1.log
```

### 8.2 Key File Locations

| File | Location |
|------|----------|
| Setup Logs | /tmp/orod/*.log |
| Grid Home | /u01/app/19c/grid |
| Grid Base | /u01/app/grid |
| DB Home | /u01/app/oracle/product/19c/dbhome_1 |
| DB Base | /u01/app/oracle |
| Inventory | /u01/app/oraInventory |
| CRS Logs | $GRID_HOME/diag/crs/$(hostname)/crs/trace/ |
| ASM Logs | $GRID_HOME/diag/asm/+asm/+ASM1/trace/ |
| DB Alert Log | $ORACLE_BASE/diag/rdbms/racdb/RACDB1/trace/ |

### 8.3 Troubleshooting Tips

1. **Always check /tmp/orod/.statefile** - Shows current deployment state
2. **Reset statefile to "pending"** to retry failed steps
3. **Check promiscuous mode** first for any network issues
4. **Verify SSH with strict checking** before running CVU/dbca
5. **Check /etc/hosts** for DNS resolution issues
6. **Monitor disk space** on /u01 during installation

### 8.4 Known Limitations

1. VirtualBox shareable disks prevent VM snapshots when attached
2. Macvlan pods cannot access Kubernetes service network (CoreDNS)
3. Password must be simple for initial deployment (complexity can break pkeyutl decryption if special chars present)
4. 50GB /scratch may be insufficient for full RU patching

---

**Document Version:** 1.0
**Created:** September 27, 2026
**Author:** Generated during RAC deployment session
