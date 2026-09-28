# Complete Oracle RAC Deployment Guide

**Purpose:** Step-by-step guide to deploy Oracle RAC on Kubernetes from scratch.
**Audience:** DBAs, Platform Engineers, Management Demo
**Environment:** OCNE 1.9, Kubernetes 1.29, Oracle Database Operator v4

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Infrastructure Overview](#2-infrastructure-overview)
3. [Step 1: Start Virtual Machines](#step-1-start-virtual-machines)
4. [Step 2: Verify Kubernetes Cluster](#step-2-verify-kubernetes-cluster)
5. [Step 3: Verify Oracle Database Operator](#step-3-verify-oracle-database-operator)
6. [Step 4: Create RAC Namespace](#step-4-create-rac-namespace)
7. [Step 5: Create Secrets](#step-5-create-secrets)
8. [Step 6: Create Network Attachment Definitions](#step-6-create-network-attachment-definitions)
9. [Step 7: Label Worker Nodes](#step-7-label-worker-nodes)
10. [Step 8: Enable Promiscuous Mode](#step-8-enable-promiscuous-mode)
11. [Step 9: Verify ASM Disks](#step-9-verify-asm-disks)
12. [Step 10: Deploy RAC Database](#step-10-deploy-rac-database)
13. [Step 11: Monitor Deployment](#step-11-monitor-deployment)
14. [Step 12: Verify RAC Cluster](#step-12-verify-rac-cluster)
15. [Appendix: Troubleshooting](#appendix-troubleshooting)

---

## 1. Prerequisites

Before starting RAC deployment, ensure the following are in place:

### 1.1 Infrastructure Requirements

| Component | Requirement | Our Setup |
|-----------|-------------|-----------|
| Hypervisor | VirtualBox 7.x | VirtualBox 7.0 |
| VMs | 4 VMs (1 operator, 1 control plane, 2 workers) | ocne-op, ocne-cp1, ocne-w1, ocne-w2 |
| Worker RAM | Minimum 16GB per worker | 20GB each |
| Worker CPU | Minimum 4 vCPU per worker | 8 vCPU each |
| Shared Storage | 2+ disks accessible by both workers | asm1.vdi, asm2.vdi (20GB each) |
| Networking | 3 networks (NAT, Host-Only, Internal) | Configured in VirtualBox |

### 1.2 Software Requirements

| Component | Version | Purpose |
|-----------|---------|---------|
| Oracle Linux | 9.8 | VM operating system |
| OCNE | 1.9 | Oracle Cloud Native Environment |
| Kubernetes | 1.29.14 | Container orchestration |
| Oracle Database Operator | v4 | Manages Oracle databases on K8s |
| Multus CNI | Included in OCNE | Multiple network interfaces |
| cert-manager | 1.12+ | TLS certificates for operator |

### 1.3 Oracle Container Registry Access

You need an Oracle account with access to:
- `container-registry.oracle.com/database/rac_ru` - RAC container images

---

## 2. Infrastructure Overview

### 2.1 Network Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         WINDOWS HOST                                     │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    VirtualBox Networks                              │ │
│  │                                                                     │ │
│  │   NAT Network          Host-Only Network      Internal Networks    │ │
│  │   10.0.2.0/24          192.168.137.0/24       192.168.10.0/24     │ │
│  │   (Internet)           (Management)           192.168.11.0/24     │ │
│  │                                               (RAC Interconnect)   │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│  │ ocne-op  │  │ ocne-cp1 │  │ ocne-w1  │  │ ocne-w2  │               │
│  │ .210     │  │ .211     │  │ .221     │  │ .222     │               │
│  │ Operator │  │ Control  │  │ Worker   │  │ Worker   │               │
│  │ NFS      │  │ Plane    │  │ RAC Node │  │ RAC Node │               │
│  └──────────┘  └──────────┘  └────┬─────┘  └────┬─────┘               │
│                                    │             │                      │
│                                    └──────┬──────┘                      │
│                                           │                             │
│                                    ┌──────▼──────┐                      │
│                                    │ Shared ASM  │                      │
│                                    │   Disks     │                      │
│                                    │ asm1, asm2  │                      │
│                                    └─────────────┘                      │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 VM Specifications

| VM | IP Address | Role | Resources |
|----|------------|------|-----------|
| ocne-op | 192.168.137.210 | OCNE Operator, NFS Server | 2 vCPU, 4GB RAM |
| ocne-cp1 | 192.168.137.211 | Kubernetes Control Plane | 4 vCPU, 6GB RAM |
| ocne-w1 | 192.168.137.221 | Worker (RAC Node 1) | 8 vCPU, 20GB RAM |
| ocne-w2 | 192.168.137.222 | Worker (RAC Node 2) | 8 vCPU, 20GB RAM |

### 2.3 Storage Layout (Workers)

| Device | Size | Purpose |
|--------|------|---------|
| /dev/sda | 60GB | Operating System |
| /dev/sdb | 50GB | Local storage (/u01 - Oracle homes) |
| /dev/sdc | 20GB | Shared ASM disk 1 (DATA diskgroup) |
| /dev/sdd | 20GB | Shared ASM disk 2 (DATA diskgroup) |

---

## Step 1: Start Virtual Machines

### Why This Order?

VMs must start in dependency order:
1. **ocne-op first** - Hosts NFS server, other nodes may mount shares
2. **ocne-cp1 second** - Kubernetes API must be available for workers
3. **Workers last** - They register with the control plane

### Commands

```powershell
# Start operator/NFS node
VBoxManage startvm ocne-op --type headless

# Wait for services to initialize
Start-Sleep -Seconds 30

# Start control plane
VBoxManage startvm ocne-cp1 --type headless

# Wait for Kubernetes API to be ready
Start-Sleep -Seconds 30

# Start workers (can be parallel)
VBoxManage startvm ocne-w1 --type headless
VBoxManage startvm ocne-w2 --type headless

# Wait for workers to fully boot
Start-Sleep -Seconds 60
```

### Verification

```bash
# Check all VMs are running
VBoxManage list runningvms
```

**Expected Output:**
```
"ocne-op" {uuid}
"ocne-cp1" {uuid}
"ocne-w1" {uuid}
"ocne-w2" {uuid}
```

---

## Step 2: Verify Kubernetes Cluster

### What We're Checking

- All nodes registered with API server
- All nodes in `Ready` state
- Correct roles assigned (control-plane, worker)

### Command

```bash
ssh root@ocne-op "kubectl get nodes -o wide"
```

### Expected Output

```
NAME                 STATUS   ROLES           AGE   VERSION          INTERNAL-IP       OS-IMAGE
ocne-cp1.lab.local   Ready    control-plane   Xd    v1.29.14+2.el9   192.168.137.211   Oracle Linux Server 9.8
ocne-w1.lab.local    Ready    worker          Xd    v1.29.14+2.el9   192.168.137.221   Oracle Linux Server 9.8
ocne-w2.lab.local    Ready    worker          Xd    v1.29.14+2.el9   192.168.137.222   Oracle Linux Server 9.8
```

### Understanding Node Status

| Status | Meaning |
|--------|---------|
| `Ready` | Node is healthy and can accept pods |
| `NotReady` | Node has issues (wait 1-2 minutes after boot) |
| `SchedulingDisabled` | Node cordoned, won't accept new pods |

---

## Step 3: Verify Oracle Database Operator

### What is the Oracle Database Operator?

A Kubernetes operator that:
- Watches for Oracle database Custom Resources (RacDatabase, SingleInstanceDatabase, etc.)
- Automates database provisioning, patching, and lifecycle management
- Runs as 3 replicas for high availability

### Command

```bash
ssh root@ocne-op "kubectl get pods -n oracle-database-operator-system"
```

### Expected Output

```
NAME                                                           READY   STATUS    RESTARTS   AGE
oracle-database-operator-controller-manager-xxxxx-xxxxx        1/1     Running   0          Xd
oracle-database-operator-controller-manager-xxxxx-xxxxx        1/1     Running   0          Xd
oracle-database-operator-controller-manager-xxxxx-xxxxx        1/1     Running   0          Xd
```

### Troubleshooting

If pods are not Running:
```bash
# Check pod events
kubectl describe pod <pod-name> -n oracle-database-operator-system

# Check operator logs
kubectl logs <pod-name> -n oracle-database-operator-system
```

---

## Step 4: Create RAC Namespace

### What is a Namespace?

A Kubernetes namespace provides:
- Logical isolation for resources
- Scope for RBAC policies
- Resource quota boundaries

### Command

```bash
ssh root@ocne-op "kubectl create namespace rac"
```

### Expected Output

```
namespace/rac created
```

### Verification

```bash
ssh root@ocne-op "kubectl get namespace rac"
```

---

## Step 5: Create Secrets

RAC deployment requires three secrets:

### 5.1 Oracle Container Registry Secret

**Purpose:** Authentication to pull Oracle container images.

**Why Needed:** Oracle RAC images are not public; you must accept license terms.

```bash
ssh root@ocne-op 'kubectl create secret docker-registry oracle-container-registry-secret \
  --docker-server=container-registry.oracle.com \
  --docker-username="your-oracle-email@example.com" \
  --docker-password="your-password" \
  --namespace=rac'
```

### 5.2 SSH Key Secret

**Purpose:** SSH keys for inter-node communication between RAC pods.

**Why Needed:** Oracle Clusterware requires SSH connectivity between nodes for:
- Cluster verification
- Remote command execution
- Software installation across nodes

```bash
# Generate SSH keys
ssh root@ocne-op 'ssh-keygen -t rsa -b 4096 -f /tmp/rac_ssh_key -N ""'

# Create secret from keys
ssh root@ocne-op 'kubectl create secret generic ssh-key-secret \
  --from-file=id_rsa=/tmp/rac_ssh_key \
  --from-file=id_rsa.pub=/tmp/rac_ssh_key.pub \
  --from-file=authorized_keys=/tmp/rac_ssh_key.pub \
  --namespace=rac'

# Clean up temporary files
ssh root@ocne-op 'rm /tmp/rac_ssh_key /tmp/rac_ssh_key.pub'
```

### 5.3 Database Password Secret

**Purpose:** Encrypted password for SYS/SYSTEM database users.

**Why Encrypted:** The operator supports encrypted passwords using RSA keys.

```bash
# Generate RSA key for encryption
ssh root@ocne-op 'openssl genrsa -out /tmp/key.pem 4096'

# Encrypt the password
ssh root@ocne-op 'echo -n "YourSecurePassword123" | openssl pkeyutl -encrypt \
  -inkey /tmp/key.pem -pkeyopt rsa_padding_mode:oaep \
  -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 \
  -out /tmp/pwdfile.enc'

# Create secret
ssh root@ocne-op 'kubectl create secret generic db-user-pass-pkutl \
  --from-file=key.pem=/tmp/key.pem \
  --from-file=pwdfile.enc=/tmp/pwdfile.enc \
  --namespace=rac'

# Clean up
ssh root@ocne-op 'rm /tmp/key.pem /tmp/pwdfile.enc'
```

### Verification

```bash
ssh root@ocne-op "kubectl get secrets -n rac"
```

**Expected Output:**
```
NAME                                TYPE                             DATA   AGE
db-user-pass-pkutl                  Opaque                           2      Xs
oracle-container-registry-secret    kubernetes.io/dockerconfigjson   1      Xs
ssh-key-secret                      Opaque                           3      Xs
```

---

## Step 6: Create Network Attachment Definitions

### What are Network Attachment Definitions?

Kubernetes Custom Resources (provided by Multus CNI) that define additional networks for pods.

### Why RAC Needs Multiple Networks

```
┌─────────────────────────────────────────────────────────────────────┐
│                        RAC Pod Networks                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  eth0 (Calico CNI)           ens1 (Macvlan)        ens2 (Macvlan)   │
│  ├── Kubernetes pod network  ├── Private           ├── Private      │
│  ├── Service communication   │   Interconnect 1    │   Interconnect 2│
│  └── External access         ├── Cache Fusion      ├── Redundant    │
│                              ├── Cluster heartbeat │   path         │
│                              └── GCS/GES traffic   └── HA failover  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Create NAD Manifest

Save as `network-attachment-definitions.yaml`:

```yaml
---
# First Private Interconnect
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rac-priv1
  namespace: rac
spec:
  config: |
    {
      "cniVersion": "0.3.0",
      "type": "macvlan",
      "master": "enp0s8",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.10.0/24",
        "rangeStart": "192.168.10.100",
        "rangeEnd": "192.168.10.120"
      }
    }

---
# Second Private Interconnect (Redundancy)
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rac-priv2
  namespace: rac
spec:
  config: |
    {
      "cniVersion": "0.3.0",
      "type": "macvlan",
      "master": "enp0s9",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.11.0/24",
        "rangeStart": "192.168.11.100",
        "rangeEnd": "192.168.11.120"
      }
    }
```

### Configuration Explained

| Field | Value | Purpose |
|-------|-------|---------|
| `type: macvlan` | Network plugin | Creates virtual NICs with unique MAC addresses |
| `master: enp0s8` | Physical NIC | Host interface to attach to |
| `mode: bridge` | Macvlan mode | Allows container-to-container communication |
| `subnet` | Network range | IP addresses for this network |
| `rangeStart/End` | IP pool | Range of IPs to assign to pods |

### Apply Configuration

```bash
ssh root@ocne-op "kubectl apply -f /path/to/network-attachment-definitions.yaml"
```

### Verification

```bash
ssh root@ocne-op "kubectl get net-attach-def -n rac"
```

**Expected Output:**
```
NAME        AGE
rac-priv1   Xs
rac-priv2   Xs
```

---

## Step 7: Label Worker Nodes

### Why Node Labels?

- RAC pods use `nodeSelector` to run on specific nodes
- Prevents accidental scheduling on non-RAC nodes
- Enables targeting specific hardware configurations

### Command

```bash
ssh root@ocne-op "kubectl label node ocne-w1.lab.local raccluster=raccluster01"
ssh root@ocne-op "kubectl label node ocne-w2.lab.local raccluster=raccluster01"
```

### Verification

```bash
ssh root@ocne-op "kubectl get nodes -l raccluster=raccluster01"
```

**Expected Output:**
```
NAME                 STATUS   ROLES    AGE   VERSION
ocne-w1.lab.local    Ready    worker   Xd    v1.29.14+2.el9
ocne-w2.lab.local    Ready    worker   Xd    v1.29.14+2.el9
```

---

## Step 8: Enable Promiscuous Mode

### What is Promiscuous Mode?

- Normally, NICs only accept packets addressed to their MAC address
- Promiscuous mode accepts ALL packets on the network segment
- Required for Macvlan - pods have their own MAC addresses

### Commands

```bash
# Enable on worker 1
ssh root@ocne-w1 "ip link set enp0s8 promisc on"
ssh root@ocne-w1 "ip link set enp0s9 promisc on"

# Enable on worker 2
ssh root@ocne-w2 "ip link set enp0s8 promisc on"
ssh root@ocne-w2 "ip link set enp0s9 promisc on"
```

### Make Persistent (survives reboot)

```bash
# On each worker
ssh root@ocne-w1 "nmcli connection modify 'System enp0s8' 802-3-ethernet.accept-all-mac-addresses yes"
ssh root@ocne-w1 "nmcli connection modify 'System enp0s9' 802-3-ethernet.accept-all-mac-addresses yes"

ssh root@ocne-w2 "nmcli connection modify 'System enp0s8' 802-3-ethernet.accept-all-mac-addresses yes"
ssh root@ocne-w2 "nmcli connection modify 'System enp0s9' 802-3-ethernet.accept-all-mac-addresses yes"
```

### Verification

```bash
ssh root@ocne-w1 "ip link show enp0s8 | grep -i promisc"
ssh root@ocne-w1 "ip link show enp0s9 | grep -i promisc"
```

**Expected Output:** Line containing `PROMISC` flag.

---

## Step 9: Verify ASM Disks

### What is ASM?

Oracle Automatic Storage Management:
- Oracle's volume manager and filesystem
- Manages database storage across multiple disks
- Provides striping, mirroring, automatic rebalancing
- Required for RAC shared storage

### Verify Disks on Both Workers

```bash
# Worker 1
ssh root@ocne-w1 "lsblk /dev/sdc /dev/sdd"

# Worker 2
ssh root@ocne-w2 "lsblk /dev/sdc /dev/sdd"
```

**Expected Output (each worker):**
```
NAME   MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
sdc      8:32   0  20G  0 disk
sdd      8:48   0  20G  0 disk
```

### Important Checks

| Check | Command | Expected |
|-------|---------|----------|
| Disks exist | `ls /dev/sd[cd]` | Both present |
| No partitions | `lsblk /dev/sdc` | No children |
| No filesystem | `blkid /dev/sdc` | No output |
| Correct size | `lsblk -b /dev/sdc` | ~20GB |

---

## Step 10: Deploy RAC Database

### The RAC Database Custom Resource

This is the main configuration that tells the Oracle Database Operator what to create.

### Key Configuration Sections

```yaml
apiVersion: database.oracle.com/v4
kind: RacDatabase
metadata:
  name: racdb01
  namespace: rac
spec:
  # How many RAC nodes
  instanceDetails:
    nodeCount: 2
    racNodeName: racnode

    # Private interconnect networks (references NADs)
    privateIPDetails:
      - name: rac-priv1
        interface: ens1
      - name: rac-priv2
        interface: ens2

    # Which nodes to run on
    workerNodeSelector:
      raccluster: raccluster01

  # Container image (pre-patched with 19.32 RU)
  image: container-registry.oracle.com/database/rac_ru:latest-19
  imagePullSecret: oracle-container-registry-secret

  # ASM storage configuration
  asmDiskGroupDetails:
    - name: DATA
      redundancy: EXTERNAL
      disks:
        - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001
        - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002

  # Database configuration
  configParams:
    dbName: "RACDB"
    pdbName: "ORCLPDB"
    sgaSize: "8G"
    pgaSize: "2G"

    # IMPORTANT: Omit ruPatchLocation for pre-patched images!
    # This saves 2-3 hours of redundant patching
```

### Apply the Configuration

```bash
# Copy to operator node
scp configs/racdb-round2.yaml root@ocne-op:/root/

# Apply
ssh root@ocne-op "kubectl apply -f /root/racdb-round2.yaml"
```

**Expected Output:**
```
racdatabase.database.oracle.com/racdb01 created
```

---

## Step 11: Monitor Deployment

### Deployment Phases and Timeline

| Phase | Duration | What's Happening |
|-------|----------|------------------|
| Pod Scheduling | 1-2 min | K8s assigns pods to nodes |
| Image Pull | 2-5 min | Pull ~17GB RAC image |
| Init Containers | 5-10 min | Network, SSH, ASM prep |
| Grid Infrastructure | 20-40 min | Clusterware, root.sh |
| Database Creation | 30-60 min | DBCA, catalog scripts |

### Monitoring Commands

```bash
# Watch pods in real-time
ssh root@ocne-op "kubectl get pods -n rac -w"

# Check RAC database status
ssh root@ocne-op "kubectl get racdatabases -n rac"

# View logs (once pods running)
ssh root@ocne-op "kubectl logs -f racnode1-0 -n rac"

# Detailed progress
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- tail -50 /tmp/orod/oracle_db_setup.log"
```

### Status Progression

| RacDatabase Status | Meaning |
|--------------------|---------|
| `Creating` | Initial setup |
| `Patching` | Applying patches (should be fast with pre-patched image) |
| `Available` | Deployment complete, RAC running |

---

## Step 12: Verify RAC Cluster

### 12.1 Check RacDatabase Resource

```bash
ssh root@ocne-op "kubectl get racdatabases -n rac"
```

**Expected:**
```
NAME      DBNAME   DBSTATE   ROLE      VERSION       PDB CONNECT STR            STATE
racdb01   RACDB    OPEN      PRIMARY   19.32.0.0.0   racnode-scan:1521/ORCLPDB  AVAILABLE
```

### 12.2 Check Cluster Status

```bash
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"crsctl check cluster -all\"'"
```

**Expected:**
```
**************************************************************
racnode1-0:
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
**************************************************************
racnode2-0:
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
**************************************************************
```

### 12.3 Check Database Instances

```bash
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"srvctl status database -d RACDB -v\"'"
```

**Expected:**
```
Instance RACDB1 is running on node racnode1-0 with online services racpdb. Instance status: Open.
Instance RACDB2 is running on node racnode2-0 with online services racpdb. Instance status: Open.
```

### 12.4 Check ASM

```bash
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"srvctl status asm\"'"
```

**Expected:**
```
ASM is running on racnode1-0,racnode2-0
```

### 12.5 Connect to Database

```bash
ssh root@ocne-op "kubectl exec -it racnode1-0 -n rac -- bash -c 'su - oracle -c \"sqlplus / as sysdba\"'"
```

```sql
-- Verify RAC instances
SELECT inst_id, instance_name, host_name, status FROM gv$instance;

-- Check PDB
SELECT con_id, name, open_mode FROM v$pdbs;
```

---

## Appendix: Troubleshooting

### Pods Stuck in Pending

```bash
kubectl describe pod racnode1-0 -n rac | grep -A 10 Events
```

Common causes:
- Node selector doesn't match any nodes
- Insufficient resources
- Image pull issues

### Pods Stuck in Init

```bash
kubectl logs racnode1-0 -n rac -c racnode1-init1
```

Common causes:
- Network configuration issues
- SSH key problems
- ASM disk not accessible

### Grid Setup Fails

```bash
kubectl exec racnode1-0 -n rac -- cat /u01/app/oraInventory/logs/GridSetupActions*/gridSetupActions*.log
```

### Database Creation Fails

```bash
kubectl exec racnode1-0 -n rac -- cat /u01/app/oracle/cfgtoollogs/dbca/RACDB/*.log
```

---

## Summary

This guide covers the complete RAC deployment process:

1. ✓ Start VMs in correct order
2. ✓ Verify Kubernetes cluster health
3. ✓ Verify Oracle Database Operator
4. ✓ Create namespace
5. ✓ Create secrets (registry, SSH, password)
6. ✓ Create Network Attachment Definitions
7. ✓ Label worker nodes
8. ✓ Enable promiscuous mode
9. ✓ Verify ASM disks
10. ✓ Deploy RAC database
11. ✓ Monitor deployment
12. ✓ Verify RAC cluster

**Key Optimization:** Using pre-patched `rac_ru:latest-19` image and omitting `ruPatchLocation` reduces deployment time from ~4-5 hours to ~1-2 hours.

---

*Document Version: 1.0*
*Created: September 2026*
