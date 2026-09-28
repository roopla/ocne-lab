# Oracle RAC Round 2 Deployment Log

**Date:** September 2026
**Environment:** OCNE 1.9 on VirtualBox
**Objective:** Deploy Oracle RAC with optimized configuration (eliminating redundant patching)

---

## Executive Summary

This document captures the complete Round 2 deployment of Oracle Real Application Clusters (RAC) on Kubernetes. The key optimization from Round 1 is **eliminating redundant patching operations**, reducing deployment time from ~4-5 hours to ~1-2 hours.

### Key Improvement from Round 1

| Aspect | Round 1 | Round 2 |
|--------|---------|---------|
| Patching approach | Specified `ruPatchLocation` (redundant) | Omitted (image pre-patched) |
| Deployment time | ~4-5 hours | ~1-2 hours (expected) |
| Cause of delay | gridSetup.sh ran with `-applyRU` flag | No patching operations |

---

## Pre-Deployment State

- **VMs:** All powered off
- **ASM Disks:** Fresh `asm1-r2.vdi` and `asm2-r2.vdi` (20GB each) attached to workers
- **Kubernetes Secrets:** Preserved from Round 1 in `rac` namespace
- **Round 1 Backup:** VM snapshots + ASM disks in `D:\VMs\shared\round1\`

---

## Deployment Steps

### Step 1: Start Virtual Machines

**Purpose:** Boot the lab infrastructure in the correct dependency order.

**Why this order?**
1. **ocne-op (Operator/NFS)** - Must start first because:
   - Hosts the NFS server with Oracle software staging
   - Runs the OLCNE operator services
   - Other nodes may mount NFS shares on boot

2. **ocne-cp1 (Control Plane)** - Must start before workers because:
   - Runs Kubernetes API server, etcd, scheduler, controller-manager
   - Workers cannot register without the control plane
   - The Oracle Database Operator runs here

3. **ocne-w1, ocne-w2 (Workers)** - Start last because:
   - They join the Kubernetes cluster by contacting the control plane
   - RAC pods will be scheduled on these nodes
   - ASM shared disks are attached to these VMs

**Commands:**
```powershell
# Start operator/NFS node
VBoxManage startvm ocne-op --type headless

# Wait 30 seconds for services to initialize
Start-Sleep -Seconds 30

# Start control plane
VBoxManage startvm ocne-cp1 --type headless

# Wait 30 seconds for Kubernetes API to be ready
Start-Sleep -Seconds 30

# Start workers (can be parallel - no dependency between them)
VBoxManage startvm ocne-w1 --type headless
VBoxManage startvm ocne-w2 --type headless
```

**Verification:**
```bash
ssh root@ocne-op "kubectl get nodes"
```

**Expected Output:**
```
NAME                 STATUS   ROLES           AGE   VERSION
ocne-cp1.lab.local   Ready    control-plane   7d    v1.29.14+2.el9
ocne-w1.lab.local    Ready    worker          7d    v1.29.14+2.el9
ocne-w2.lab.local    Ready    worker          7d    v1.29.14+2.el9
```

**Actual Output:**
```
[To be filled during deployment]
```

---

### Step 2: Verify Oracle Database Operator

**Purpose:** Ensure the operator that manages RAC deployments is running.

**What is the Oracle Database Operator?**
- A Kubernetes operator that automates Oracle database lifecycle
- Watches for `RacDatabase` custom resources
- Creates pods, services, and manages Oracle RAC installation
- Runs as 3 replicas for high availability

**Command:**
```bash
ssh root@ocne-op "kubectl get pods -n oracle-database-operator-system"
```

**Expected Output:**
```
NAME                                                           READY   STATUS    RESTARTS   AGE
oracle-database-operator-controller-manager-xxxxx-xxxxx        1/1     Running   0          ...
oracle-database-operator-controller-manager-xxxxx-xxxxx        1/1     Running   0          ...
oracle-database-operator-controller-manager-xxxxx-xxxxx        1/1     Running   0          ...
```

**What if pods aren't Running?**
- Wait 2-3 minutes for container images to pull
- Check events: `kubectl describe pod <pod-name> -n oracle-database-operator-system`

**Actual Output:**
```
[To be filled during deployment]
```

---

### Step 3: Verify Prerequisites in RAC Namespace

**Purpose:** Confirm secrets from Round 1 are intact and ready for reuse.

**What secrets are needed?**

| Secret | Purpose |
|--------|---------|
| `oracle-container-registry-secret` | Authentication to pull Oracle container images |
| `ssh-key-secret` | SSH keys for inter-node communication (RAC requirement) |
| `db-user-pass-pkutl` | Database SYS/SYSTEM password (encrypted) |

**Command:**
```bash
ssh root@ocne-op "kubectl get secrets -n rac"
```

**Expected Output:**
```
NAME                                TYPE                             DATA   AGE
db-user-pass-pkutl                  Opaque                           2      ...
oracle-container-registry-secret    kubernetes.io/dockerconfigjson   1      ...
ssh-key-secret                      Opaque                           2      ...
```

**Actual Output:**
```
[To be filled during deployment]
```

---

### Step 4: Verify Network Attachment Definitions

**Purpose:** Confirm Multus CNI network definitions exist for RAC private interconnects.

**What are Network Attachment Definitions?**
- Kubernetes CRDs that define additional networks for pods
- RAC requires private interconnect networks for:
  - Cache Fusion (sharing data blocks between instances)
  - Cluster heartbeat communication
  - Global Cache Service (GCS) / Global Enqueue Service (GES)

**Why two private networks?**
- Redundancy - if one network fails, the other maintains cluster communication
- Prevents split-brain scenarios

**Command:**
```bash
ssh root@ocne-op "kubectl get net-attach-def -n rac"
```

**Expected Output:**
```
NAME        AGE
rac-priv1   ...
rac-priv2   ...
```

**Actual Output:**
```
[To be filled during deployment]
```

---

### Step 5: Verify ASM Disks on Workers

**Purpose:** Confirm shared storage disks are visible and accessible on both worker nodes.

**What is ASM (Automatic Storage Management)?**
- Oracle's volume manager and filesystem for database files
- Provides striping, mirroring, and automatic rebalancing
- Required for RAC shared storage

**Why shared disks?**
- Both RAC nodes must access the same database files
- ASM manages concurrent access safely
- VirtualBox "shareable" disk mode enables this in our lab

**Commands:**
```bash
# Check on worker 1
ssh root@ocne-w1 "ls -la /dev/sd[cd] && lsblk /dev/sdc /dev/sdd"

# Check on worker 2
ssh root@ocne-w2 "ls -la /dev/sd[cd] && lsblk /dev/sdc /dev/sdd"
```

**Expected Output:**
- `/dev/sdc` and `/dev/sdd` present on both nodes
- Size: 20GB each
- No partitions (raw block devices)

**Actual Output:**
```
[To be filled during deployment]
```

---

### Step 6: Verify Worker Node Labels

**Purpose:** Confirm workers are labeled for RAC pod scheduling.

**Why node labels?**
- RAC pods use `nodeSelector` to run only on designated nodes
- Label `raccluster=raccluster01` identifies nodes for this RAC cluster
- Prevents accidental scheduling on non-RAC nodes

**Command:**
```bash
ssh root@ocne-op "kubectl get nodes -l raccluster=raccluster01"
```

**Expected Output:**
```
NAME                 STATUS   ROLES    AGE   VERSION
ocne-w1.lab.local    Ready    worker   7d    v1.29.14+2.el9
ocne-w2.lab.local    Ready    worker   7d    v1.29.14+2.el9
```

**Actual Output:**
```
[To be filled during deployment]
```

---

### Step 7: Enable Promiscuous Mode on Workers

**Purpose:** Allow Macvlan network interfaces to function properly.

**What is promiscuous mode?**
- Normally, a NIC only receives packets addressed to its MAC address
- Promiscuous mode allows receiving ALL packets on the network segment
- Required for Macvlan CNI - containers get their own MAC addresses

**Why is this needed for RAC?**
- RAC pods use Macvlan for private interconnect networks
- Each pod gets unique IP/MAC on the interconnect
- Without promiscuous mode, packets to pod MAC addresses are dropped

**Commands:**
```bash
# Enable on worker 1
ssh root@ocne-w1 "ip link set enp0s8 promisc on && ip link set enp0s9 promisc on"

# Enable on worker 2
ssh root@ocne-w2 "ip link set enp0s8 promisc on && ip link set enp0s9 promisc on"

# Verify
ssh root@ocne-w1 "ip link show enp0s8 | grep -i promisc"
```

**Expected Output:**
Line containing `PROMISC` flag.

**Actual Output:**
```
[To be filled during deployment]
```

---

### Step 8: Deploy RAC Database (The Main Event)

**Purpose:** Create the Oracle RAC cluster using the optimized configuration.

**What happens when we apply racdb-round2.yaml?**

1. **Operator receives the RacDatabase CR** (Custom Resource)
2. **Operator creates StatefulSet** for RAC pods
3. **Pods are scheduled** on labeled worker nodes
4. **Init containers run:**
   - Configure networking
   - Set up SSH between nodes
   - Prepare ASM devices
5. **Main container starts Grid Infrastructure setup:**
   - Configure Oracle Clusterware
   - Create ASM disk group (+DATA)
   - Start cluster services
6. **Database creation:**
   - Run DBCA to create RAC database
   - Create PDB (pluggable database)
   - Configure services and listeners

**Key difference from Round 1:**
```yaml
# Round 1 (SLOW - redundant patching):
configParams:
  ruPatchLocation: "/scratch/software/stage/19c/19.29/RU/39467003"
  oPatchLocation: "/scratch/software/stage/19c/19.29/OPATCH"

# Round 2 (FAST - no patching):
configParams:
  # These lines are OMITTED - image already has 19.32 RU!
```

**Command:**
```bash
# Copy config to operator node
scp configs/racdb-round2.yaml root@ocne-op:/root/

# Apply the configuration
ssh root@ocne-op "kubectl apply -f /root/racdb-round2.yaml"
```

**Expected Output:**
```
racdatabase.database.oracle.com/racdb01 created
```

**Actual Output:**
```
[To be filled during deployment]
```

---

### Step 9: Monitor Deployment Progress

**Purpose:** Track the RAC deployment through its phases.

**Deployment Phases:**

| Phase | Duration (Est.) | What's Happening |
|-------|-----------------|------------------|
| Pod scheduling | 1-2 min | Kubernetes assigns pods to nodes |
| Image pull | 2-5 min | Pull 17GB RAC image (if not cached) |
| Init containers | 5-10 min | Network setup, SSH config, ASM prep |
| Grid Infrastructure | 20-40 min | Clusterware setup, root.sh execution |
| Database creation | 30-60 min | DBCA, catalog scripts, PDB creation |

**Monitoring Commands:**

```bash
# Watch pods (Ctrl+C to exit)
ssh root@ocne-op "kubectl get pods -n rac -w"

# Check RAC database status
ssh root@ocne-op "kubectl get racdatabases -n rac"

# View deployment logs (once pods are running)
ssh root@ocne-op "kubectl logs -f racnode1-0 -n rac"

# Check detailed progress inside pod
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- tail -100 /tmp/orod/oracle_db_setup.log"
```

**Status Progression:**
1. `Pending` → Waiting for scheduling
2. `Init:0/1` → Init containers running
3. `Running` → Main container started
4. RAC Status: `Creating` → `Patching` (should be quick/skipped) → `Available`

**Actual Progress Log:**
```
[To be filled during deployment with timestamps]
```

---

### Step 10: Verify Successful Deployment

**Purpose:** Confirm RAC cluster is fully operational.

**Verification Commands:**

```bash
# 1. Check RAC Database CR status
ssh root@ocne-op "kubectl get racdatabases -n rac"
# Expected: STATE = AVAILABLE

# 2. Check cluster status
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"crsctl check cluster -all\"'"

# 3. Check database instances
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"srvctl status database -d RACDB -v\"'"

# 4. Check ASM
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"srvctl status asm\"'"

# 5. List all CRS resources
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"crsctl stat res -t\"'"
```

**Expected Final State:**
- Both RAC instances (RACDB1, RACDB2) running
- Both ASM instances (+ASM1, +ASM2) running
- PDB (ORCLPDB) open
- All CRS resources online

**Actual Output:**
```
[To be filled during deployment]
```

---

## Deployment Timeline

| Time | Event | Notes |
|------|-------|-------|
| | VMs started | |
| | Operator verified | |
| | Prerequisites confirmed | |
| | RAC deployment started | |
| | Pods scheduled | |
| | Grid setup started | |
| | Grid setup completed | |
| | Database creation started | |
| | Database creation completed | |
| | **DEPLOYMENT COMPLETE** | |

**Total Deployment Time:** [To be filled]

---

## Comparison: Round 1 vs Round 2

| Metric | Round 1 | Round 2 |
|--------|---------|---------|
| Total deployment time | ~4-5 hours | [To be filled] |
| Patching time | ~2-3 hours | [To be filled] |
| Grid setup time | ~40 min | [To be filled] |
| Database creation time | ~60 min | [To be filled] |

**Time Saved:** [To be calculated]

---

## Lessons Learned

1. **Image selection matters:** Using `rac_ru:latest-19` with pre-applied patches eliminates hours of redundant work.

2. **Configuration optimization:** Omitting `ruPatchLocation` when image is already patched prevents `gridSetup.sh -applyRU` from running.

3. **Documentation value:** Step-by-step documentation enables reproducible deployments and effective knowledge transfer.

---

*Document will be updated as deployment progresses.*
