# Oracle RAC Operator: HostPath Volume Architecture

This document explains why the Oracle Database Operator uses hostPath volumes that overwrite pre-installed container software, and the implications for deployment.

---

## The Problem: Pre-Built Images Don't Help

### What You Might Expect

When using Oracle's pre-built Release Update image (`rac_ru:latest-19`), you might expect:

```
Container Image (17GB)
├── /u01/app/19c/grid/          ← Grid Infrastructure binaries (19.32)
├── /u01/app/oracle/product/    ← Database binaries (19.32)
└── Ready to run!
```

**Expectation:** Container starts with software pre-installed, no extraction needed.

### What Actually Happens

```
1. Pod is scheduled on worker node

2. Kubernetes creates container from rac_ru:latest-19 image
   Container filesystem:
   └── /u01/ ← Contains pre-installed Oracle software

3. Operator defines hostPath volume mount:
   volumes:
   - name: racnode2-oradata-sw-vol
     hostPath:
       path: /scratch/rac/cluster01/racnode2   ← EMPTY directory on host

4. Volume is mounted into container:
   volumeMounts:
   - name: racnode2-oradata-sw-vol
     mountPath: /u01                            ← OVERWRITES container's /u01!

5. Result: Container's /u01 is now EMPTY
   The pre-installed software is GONE
```

### Verification

You can verify this inside a running RAC pod:

```bash
# Check the /u01 mount
kubectl exec racnode2-0 -n rac -- mount | grep u01
# Output: /dev/sda2 on /u01 type xfs (rw,relatime,...)

# Check /u01 contents (empty on fresh deployment)
kubectl exec racnode2-0 -n rac -- ls -la /u01
# Output: Empty directory
```

---

## Why Does the Operator Do This?

The Oracle Database Operator was designed with **traditional deployment patterns** in mind, not container-native patterns.

### 1. Persistence Requirement

Oracle software and data **must survive pod restarts**:

```
Pod restart scenario without hostPath:
  - Pod deleted → Container destroyed
  - Pod recreated → Fresh container
  - All Oracle configuration LOST
  - Database files LOST

Pod restart scenario WITH hostPath:
  - Pod deleted → Container destroyed
  - Pod recreated → Fresh container
  - hostPath remounted → /u01 preserved
  - Oracle configuration INTACT
  - Database files INTACT
```

### 2. Cluster Consistency

In a RAC cluster, all nodes must have identical Oracle homes:

```
Traditional RAC:
  Node 1: /u01/app/19c/grid → NFS mount
  Node 2: /u01/app/19c/grid → Same NFS mount

Kubernetes RAC:
  racnode1-0: /u01 → hostPath on ocne-w1
  racnode2-0: /u01 → hostPath on ocne-w2

  Software must be COPIED from first node to others
  to ensure consistency (same patch level, same binaries)
```

### 3. Upgrade Path Support

The Operator supports in-place upgrades and patching:

```
Upgrade scenario:
  1. Stop database
  2. Apply patches to /u01/app/19c/grid (hostPath)
  3. Restart database
  4. hostPath preserves patched software

With container image:
  - Patching container filesystem doesn't persist
  - New container = original unpatched binaries
```

### 4. Storage Design Assumption

The Operator assumes software comes from one of:

```yaml
Option A: Staged zip files (Oracle's expected method)
configParams:
  hostSwStageLocation: "/scratch/software/stage"
  gridSwZipFile: "LINUX.X64_193000_grid_home.zip"
  dbSwZipFile: "LINUX.X64_193000_db_home.zip"

Option B: Copied from first node
# Operator detects empty /u01 on secondary nodes
# Attempts to copy via SSH from primary node
```

---

## The Three Deployment Options

### Option 1: Stage Software on NFS (Oracle's Intended Method)

This is what Oracle documents and expects:

```yaml
# Mount NFS with staged software
volumeMounts:
- mountPath: /scratch/software/stage
  name: nfs-stage

# Operator extracts to hostPath
configParams:
  hostSwStageLocation: "/scratch/software/stage"
  gridSwZipFile: "LINUX.X64_193000_grid_home.zip"
  dbSwZipFile: "LINUX.X64_193000_db_home.zip"
```

**Flow:**
1. Stage Oracle zip files on NFS
2. Operator extracts to /u01 (hostPath)
3. Apply patches if `ruPatchLocation` specified
4. Software persists across restarts

**Pros:**
- Works reliably
- Supports patching workflow
- Oracle-supported method

**Cons:**
- Requires NFS setup
- Large zip files (~10GB+)
- Extraction takes time

### Option 2: Reuse Existing hostPath Data

If you've done a previous deployment, the hostPath already has software:

```
ocne-w1:/scratch/rac/cluster01/racnode1/
├── app/19c/grid/      ← Grid from previous deployment
└── app/oracle/        ← Database from previous deployment
```

**Flow:**
1. First deployment populates hostPath
2. Subsequent deployments reuse existing software
3. New pods use preserved /u01 data

**Pros:**
- Fast (no extraction)
- No NFS needed
- Works for lab environments

**Cons:**
- Only works after first successful deployment
- Secondary nodes still need software copied
- Not a "fresh" deployment

### Option 3: Manual Software Copy

For secondary nodes when SSH copy fails:

```bash
# Copy from worker1's hostPath to worker2's hostPath
rsync -av root@ocne-w1:/scratch/rac/cluster01/racnode1/ \
          /scratch/rac/cluster01/racnode2/
```

**Flow:**
1. Primary node has software (from staging or previous deployment)
2. Manually copy to secondary node's hostPath
3. Restart secondary pod
4. Pod sees software in /u01

**Pros:**
- Bypasses SSH setup issues
- Works when automation fails

**Cons:**
- Manual intervention required
- Requires node-to-node access
- Not automated

---

## Why Pre-Built Images Still Have Value

Even though hostPath overwrites the container's software, the pre-built `rac_ru` image is still valuable:

### 1. Faster Image Pull

```
rac:latest     → 10GB base, then extract 20GB+
rac_ru:latest  → 17GB pre-built, already patched
```

The pre-built image pulls faster than extracting on first use.

### 2. Patch Verification

You can verify patch levels before deployment:

```bash
# Check what patches are in the image
kubectl run test --rm -it --image=rac_ru:latest-19 --privileged=true \
  -- su - grid -c "/u01/app/19c/grid/OPatch/opatch lspatches"
```

### 3. First Node Bootstrap

On the **first node** (racnode1-0), before any volumes are mounted:
- Init containers may copy from container to hostPath
- OR staging/extraction populates hostPath
- Once populated, hostPath is authoritative

---

## Disk Space Implications

Each worker node needs sufficient disk space for:

| Component | Size | Location |
|-----------|------|----------|
| Container images | ~17GB | /var/lib/containerd |
| Grid Infrastructure | ~12GB | /scratch/rac/cluster01/racnodeX/app/19c/grid |
| Database Home | ~13GB | /scratch/rac/cluster01/racnodeX/app/oracle |
| Logs/Diagnostics | ~2-5GB | /scratch/rac/cluster01/racnodeX/app/... |
| **Total hostPath** | **~25-30GB** | /scratch/rac/cluster01 |

**Recommendation:** Worker nodes need at least **60GB root disk** for comfortable RAC deployment.

---

## Practical Recommendations

### For Lab/Development

1. **First deployment:** Use NFS staging with zip files
2. **Subsequent rounds:** Reuse hostPath from first deployment
3. **If SSH copy fails:** Use manual rsync between nodes

### For Production

1. **Use NFS staging** as Oracle documents
2. **Size disks appropriately** (60GB+ per worker)
3. **Test upgrade/patch procedures** before production use

### For This Lab (Round 2)

Since Round 1 populated hostPath on ocne-w1:
1. racnode1-0 reuses existing /u01 data ✓
2. racnode2-0's hostPath was empty (new ASM disks scenario)
3. Solution: Copy software from w1 to w2 manually

---

## Diagram: Volume Mount Sequence

```
┌─────────────────────────────────────────────────────────────────┐
│                    Container Image                               │
│  rac_ru:latest-19 (17GB)                                        │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ /u01/app/19c/grid/  (Grid Infrastructure 19.32)             ││
│  │ /u01/app/oracle/    (Database 19.32)                        ││
│  │ /u01/app/oraInventory/                                      ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Container created
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Container Runtime                             │
│  Container's /u01 = image layer (read-only) + overlay (rw)     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ hostPath volume mounted
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    After Volume Mount                            │
│  Container's /u01 = hostPath mount                              │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ /u01 → /scratch/rac/cluster01/racnode2 (host filesystem)   ││
│  │                                                              ││
│  │ If empty: Software must be extracted or copied               ││
│  │ If populated: Previous software preserved                    ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  Image's original /u01 contents are HIDDEN (mount shadowing)    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Takeaway

> **The `rac_ru:latest-19` image contains pre-installed software, but the Oracle Database Operator's hostPath architecture means this software is never used. The hostPath mount shadows (overwrites) the container's /u01 directory.**

This is a fundamental design decision by Oracle's Operator team to support:
- Persistence across pod restarts
- In-place patching and upgrades
- Traditional Oracle deployment patterns

Understanding this architecture is critical for:
- Troubleshooting deployment issues
- Planning disk space requirements
- Choosing deployment options

---

*Document Version: 1.0*
*Created: September 2026*
*Based on: Oracle Database Operator v4 behavior analysis*
