# RacDatabase Resource Creation Sequence

When you apply a `RacDatabase` manifest, the Oracle Database Operator creates multiple Kubernetes resources in a specific sequence. This document explains each resource, its purpose, and how they connect.

---

## Overview

```
kubectl apply -f racdb-round2.yaml
                    │
                    ▼
          ┌─────────────────┐
          │ Oracle Database │
          │    Operator     │
          │ (watches CRDs)  │
          └────────┬────────┘
                   │
                   ▼
    ┌──────────────────────────────────┐
    │  Resources Created (in order):   │
    │  1. DaemonSet (disk-check)       │
    │  2. Services (SCAN, VIP, Lsnr)   │
    │  3. StatefulSet (RAC pods)       │
    │  4. ConfigMaps                   │
    │  5. PersistentVolumeClaims       │
    └──────────────────────────────────┘
```

---

## Resource Creation Sequence

### Phase 1: Pre-flight Checks

#### 1. DaemonSet: `disk-check-daemonset`

**Command to view:**
```bash
kubectl get daemonset -n rac
kubectl describe daemonset disk-check-daemonset -n rac
```

**Purpose:**
- Runs a pod on EVERY node in the cluster
- Verifies that ASM disks (`/dev/sdc`, `/dev/sdd`) are accessible
- Ensures disk permissions are correct (owned by 54321:54321)
- Reports disk discovery results back to the operator

**Why a DaemonSet?**
- DaemonSets guarantee exactly one pod per node
- RAC needs to verify disks on both worker nodes before proceeding
- If disk check fails on any node, deployment stops early (fail-fast)

**Connection to other resources:**
- Must complete successfully before StatefulSet is created
- Uses the same container image as RAC pods (`rac_ru:latest-19`)

---

### Phase 2: Networking Setup

The operator creates Services BEFORE pods so that DNS names are available when pods start.

#### 2. Service: `racnode-scan` (Headless)

**Command to view:**
```bash
kubectl get svc racnode-scan -n rac -o yaml
```

**Type:** ClusterIP: None (Headless)

**Purpose:**
- SCAN (Single Client Access Name) for RAC cluster
- Provides DNS-based load balancing across RAC nodes
- Clients connect to `racnode-scan.rac.svc.cluster.local`
- Kubernetes DNS returns IPs of all ready RAC pods

**Why Headless?**
- Headless services don't have a single ClusterIP
- DNS queries return multiple A records (one per pod)
- Client-side load balancing / Oracle Net handles distribution

---

#### 3. Service: `racnode-scan-lsnr` (NodePort)

**Command to view:**
```bash
kubectl get svc racnode-scan-lsnr -n rac
```

**Type:** NodePort (port 1521 → 31521)

**Purpose:**
- Exposes Oracle listener for EXTERNAL client access
- Clients outside the cluster connect to `<any-node-ip>:31521`
- Traffic is forwarded to SCAN listener inside the cluster

**Connection:**
```
External Client → NodeIP:31521 → SCAN Listener → RAC Instance
```

---

#### 4. Services: `racnode1-0`, `racnode2-0` (Headless)

**Command to view:**
```bash
kubectl get svc racnode1-0 racnode2-0 -n rac
```

**Type:** ClusterIP: None (Headless)

**Purpose:**
- Provides stable DNS name for each specific RAC node
- `racnode1-0.rac.svc.cluster.local` → Pod racnode1-0
- `racnode2-0.rac.svc.cluster.local` → Pod racnode2-0
- Used for node-specific connections and Grid Infrastructure

---

#### 5. Services: `racnode1-0-vip`, `racnode2-0-vip` (Headless)

**Command to view:**
```bash
kubectl get svc racnode1-0-vip racnode2-0-vip -n rac
```

**Type:** ClusterIP: None (Headless)

**Purpose:**
- VIP (Virtual IP) services for RAC failover
- In traditional RAC, VIPs float between nodes during failover
- In Kubernetes, these are DNS-based services that point to the pod

---

#### 6. Services: `racnode1-0-lsnr`, `racnode2-0-lsnr` (NodePort)

**Command to view:**
```bash
kubectl get svc racnode1-0-lsnr racnode2-0-lsnr -n rac
```

**Ports:**
- racnode1-0-lsnr: 31522:31522/TCP
- racnode2-0-lsnr: 31523:31523/TCP

**Purpose:**
- Node-specific listener access from outside the cluster
- Allows direct connection to a specific RAC instance
- Useful for testing or instance-specific operations

---

#### 7. Services: `racnode1-0-ons`, `racnode2-0-ons` (NodePort)

**Command to view:**
```bash
kubectl get svc racnode1-0-ons racnode2-0-ons -n rac
```

**Ports:**
- racnode1-0-ons: 6200:30200/TCP
- racnode2-0-ons: 6200:30201/TCP

**Purpose:**
- ONS (Oracle Notification Services) for FAN (Fast Application Notification)
- Used by connection pools and clients to receive failover events
- When a node fails, ONS broadcasts events so clients can reconnect quickly

---

### Phase 3: Pod Creation

#### 8. StatefulSet: `racnode1`, `racnode2`

**Command to view:**
```bash
kubectl get statefulset -n rac
kubectl describe statefulset racnode1 -n rac
```

**Purpose:**
- Creates RAC pods with stable identities (racnode1-0, racnode2-0)
- Ensures pods are created in order (racnode1-0 first, then racnode2-0)
- Provides stable network identities that survive pod restarts

**Why StatefulSet (not Deployment)?**
- RAC nodes need stable hostnames (racnode1-0, racnode2-0)
- Pods must be created in sequence (first node initializes cluster)
- PVCs must be retained across pod restarts

---

#### 9. Pods: `racnode1-0`, `racnode2-0`

**Command to view:**
```bash
kubectl get pods -n rac
kubectl describe pod racnode1-0 -n rac
```

**Structure:**
```
Pod: racnode1-0
├── Init Containers:
│   ├── racnode1-init1    (Network setup)
│   ├── racnode1-init2    (SSH setup)
│   └── racnode1-init3    (ASM prep)
└── Main Container:
    └── racnode1-0        (Oracle RAC)
```

**Init Containers (run in sequence before main container):**

| Container | Purpose |
|-----------|---------|
| `racnode1-init1` | Configures additional network interfaces (Macvlan) |
| `racnode1-init2` | Sets up SSH keys for passwordless communication between nodes |
| `racnode1-init3` | Prepares ASM disks, sets permissions |

**Main Container:**
- Runs Oracle Grid Infrastructure and Database
- Executes `gridSetup.sh` to configure Clusterware
- Runs `root.sh` for privileged setup
- Executes DBCA to create RAC database

---

### Phase 4: Storage (If applicable)

#### 10. PersistentVolumeClaims

**Command to view:**
```bash
kubectl get pvc -n rac
```

**Note:** In our deployment, we use hostPath/block devices for ASM rather than PVCs. PVCs would be created if using storage classes.

---

## Complete Resource Map

```
RacDatabase CR (racdb01)
│
├── DaemonSet: disk-check-daemonset
│   ├── Pod: disk-check-daemonset-xxxxx (on ocne-w1)
│   └── Pod: disk-check-daemonset-xxxxx (on ocne-w2)
│
├── Services (Networking):
│   ├── racnode-scan (Headless SCAN)
│   ├── racnode-scan-lsnr (NodePort 31521)
│   ├── racnode1-0 (Headless)
│   ├── racnode1-0-vip (Headless VIP)
│   ├── racnode1-0-lsnr (NodePort 31522)
│   ├── racnode1-0-ons (NodePort 30200)
│   ├── racnode2-0 (Headless)
│   ├── racnode2-0-vip (Headless VIP)
│   ├── racnode2-0-lsnr (NodePort 31523)
│   └── racnode2-0-ons (NodePort 30201)
│
└── StatefulSets:
    ├── racnode1
    │   └── Pod: racnode1-0 (on ocne-w1)
    │       ├── Init: racnode1-init1, init2, init3
    │       └── Main: racnode1-0
    │
    └── racnode2
        └── Pod: racnode2-0 (on ocne-w2)
            ├── Init: racnode2-init1, init2, init3
            └── Main: racnode2-0
```

---

## Viewing Commands Quick Reference

```bash
# All resources in rac namespace
kubectl get all -n rac

# RacDatabase custom resource status
kubectl get racdatabases -n rac -o wide

# Services with endpoints
kubectl get svc -n rac -o wide

# Pods with node placement
kubectl get pods -n rac -o wide

# Detailed pod events
kubectl describe pod racnode1-0 -n rac

# Init container logs
kubectl logs racnode1-0 -n rac -c racnode1-init1

# Main container logs
kubectl logs racnode1-0 -n rac -c racnode1-0

# Watch real-time pod creation
kubectl get pods -n rac -w
```

---

## Service Ports Summary

| Service | Type | Internal Port | External Port | Purpose |
|---------|------|---------------|---------------|---------|
| racnode-scan | Headless | - | - | SCAN DNS |
| racnode-scan-lsnr | NodePort | 1521 | 31521 | SCAN listener (external) |
| racnode1-0-lsnr | NodePort | 31522 | 31522 | Node 1 listener |
| racnode2-0-lsnr | NodePort | 31523 | 31523 | Node 2 listener |
| racnode1-0-ons | NodePort | 6200 | 30200 | Node 1 ONS |
| racnode2-0-ons | NodePort | 6200 | 30201 | Node 2 ONS |

---

## Connection Flow

```
┌─────────────────┐
│ External Client │
└────────┬────────┘
         │
         │ Connect to NodeIP:31521
         ▼
┌─────────────────────┐
│ racnode-scan-lsnr   │
│ (NodePort Service)  │
└────────┬────────────┘
         │
         │ Forward to pod IP:1521
         ▼
┌─────────────────────┐
│ SCAN Listener       │
│ (inside RAC pod)    │
└────────┬────────────┘
         │
         │ Route to least-loaded instance
         ▼
┌─────────────────────┐
│ RACDB1 or RACDB2    │
│ (Database Instance) │
└─────────────────────┘
```

---

*Document Version: 1.0*
*Created: September 2026*
