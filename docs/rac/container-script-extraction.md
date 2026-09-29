# Extracting and Analyzing Oracle RAC Container Scripts

This document describes how to extract source code from Oracle container images and documents the findings from analyzing the RAC operator startup scripts.

---

## Part 1: How to Extract Source Code from Container Images

### Method A: Using Kubernetes (kubectl exec)

This method runs a temporary pod with the target image and allows you to explore interactively.

#### Step 1: Create Temporary Namespace and Pod

```bash
# Create isolated namespace
kubectl create namespace temp-extract

# Run pod with target image (sleep command keeps it running)
kubectl run extract -n temp-extract \
  --image=container-registry.oracle.com/database/rac_ru:latest-19 \
  --restart=Never \
  --command -- sleep 3600

# Wait for pod to be ready
kubectl get pod extract -n temp-extract -w
```

#### Step 2: Explore Container Filesystem

```bash
# List directory contents
kubectl exec extract -n temp-extract -- ls -la /opt/scripts/startup/scripts/

# Search for specific functions across all Python files
kubectl exec extract -n temp-extract -- bash -c "grep -rn 'def check_home' /opt/scripts/startup/scripts/"

# Extract specific line ranges from a file
kubectl exec extract -n temp-extract -- sed -n '90,150p' /opt/scripts/startup/scripts/oragiprov.py

# Find files matching a pattern
kubectl exec extract -n temp-extract -- bash -c "find /opt -name '*.py' 2>/dev/null | head -20"

# Check file sizes
kubectl exec extract -n temp-extract -- du -sh /opt/scripts/startup/scripts/

# View file with line numbers
kubectl exec extract -n temp-extract -- cat -n /opt/scripts/startup/scripts/main.py
```

#### Step 3: Copy Files to Local Machine

```bash
# Copy single file
kubectl cp temp-extract/extract:/opt/scripts/startup/scripts/main.py ./main.py

# Copy entire directory
kubectl cp temp-extract/extract:/opt/scripts/startup/scripts/ ./oracle-scripts/

# Copy with tar (preserves permissions)
kubectl exec extract -n temp-extract -- tar cf - /opt/scripts/startup/scripts/ | tar xf - -C ./
```

#### Step 4: Cleanup

```bash
kubectl delete namespace temp-extract
```

---

### Method B: Using Docker/Podman Directly

If you have direct container runtime access (no Kubernetes needed):

```bash
# Create container without starting it
docker create --name extract container-registry.oracle.com/database/rac_ru:latest-19

# Copy files out
docker cp extract:/opt/scripts/startup/scripts/ ./oracle-scripts/

# Or explore interactively
docker run --rm -it container-registry.oracle.com/database/rac_ru:latest-19 bash

# Cleanup
docker rm extract
```

---

### Method C: Using Skopeo + Umoci (No Container Runtime)

For extracting without running any container:

```bash
# Download image as OCI directory
skopeo copy docker://container-registry.oracle.com/database/rac_ru:latest-19 oci:rac_image:latest

# Extract filesystem layers
umoci unpack --image rac_image:latest bundle

# Browse extracted filesystem
ls bundle/rootfs/opt/scripts/startup/scripts/
```

---

## Part 2: Oracle RAC Startup Script Analysis

### Key Files Discovered

| File | Size | Purpose |
|------|------|---------|
| `/opt/scripts/startup/scripts/main.py` | 2KB | Entry point, calls OraFactory |
| `/opt/scripts/startup/scripts/oracommon.py` | 183KB | Core utilities, helper functions |
| `/opt/scripts/startup/scripts/oragiprov.py` | 45KB | Grid Infrastructure provisioning |
| `/opt/scripts/startup/scripts/oracvu.py` | 25KB | Cluster Verification Utility wrappers |
| `/opt/scripts/startup/scripts/orasetupenv.py` | 40KB | Environment setup and software extraction |

### Software Detection Flow

```
Container Startup
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  orasetupenv.py: set_banner()                               │
│                                                             │
│  1. Check GI_SW_UNZIPPED_FLAG                               │
│     └─► If set: Software was just unzipped, skip checks    │
│                                                             │
│  2. Call check_home(gihome)                                 │
│     └─► Checks: {GRID_HOME}/bin/cluvfy exists?             │
│         └─► If not exists: return 1 (failure)              │
│         └─► If exists: run "cluvfy comp software"          │
│             └─► If no "FAILED" in output: return 0         │
│                                                             │
│  3. Call check_gi_installed(retcode, gihome, ...)          │
│     └─► If retcode == 0 AND /etc/oracle exists:            │
│         └─► Set GI_HOME_CONFIGURED_FLAG=true               │
│         └─► "Grid is already installed... Skipping"        │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  oragiprov.py: setup()                                      │
│                                                             │
│  if GI_HOME_CONFIGURED_FLAG is set:                         │
│     └─► SKIP ALL SETUP (Grid already configured)           │
│                                                             │
│  else:                                                      │
│     └─► if retcode1 != 0 AND COPY_GRID_SOFTWARE set:       │
│         └─► crs_sw_install() - Extract/copy software       │
│     └─► crs_config_install() - Configure Grid              │
│     └─► run_rootsh() - Run root.sh                         │
└─────────────────────────────────────────────────────────────┘
```

### Key Functions

#### check_home() in oracvu.py (line 217)
```python
def check_home(self, node, home, user):
    cvufile = '{0}/bin/cluvfy'.format(gihome)
    if not self.ocommon.check_file(cvufile, True, None, None):
        return 1  # cluvfy doesn't exist

    cmd = 'su - {0} -c "{1}/bin/cluvfy comp software -d {2} -verbose"'
    output, error, retcode = self.ocommon.execute_cmd(cmd, None, None)
    if not self.ocommon.check_substr_match(output, "FAILED"):
        return 0  # Success
    else:
        return 1  # Failure
```

#### check_gi_installed() in oracommon.py (line 1933)
```python
def check_gi_installed(self, retcode1, gihome, giuser, node, oinv):
    if retcode1 == 0:
        if os.path.isdir("/etc/oracle"):
            # Grid is already installed, skip setup
            return True
        else:
            # Grid home exists but /etc/oracle missing
            # Attempt to restore from backup
            ...
    else:
        # Grid is not installed
        return False
```

### Critical Discovery: Pre-Built Image Limitations

The `rac_ru:latest-19` pre-built image contains Oracle software but is **missing components created during configuration**:

| Component | In Pre-Built Image? | Created When? |
|-----------|---------------------|---------------|
| `/u01/app/19c/grid/` (Grid home) | ✅ Yes | Image build |
| `/u01/app/oracle/product/19c/dbhome_1/` | ✅ Yes | Image build |
| `/u01/app/19c/grid/bin/cluvfy` | ❌ **No** | Grid configuration |
| `/etc/oracle/` directory | ❌ **No** | Grid configuration |
| OraInventory (complete) | ⚠️ Partial | Grid configuration |

**Implication**: Simply copying software from the container image to hostPath will NOT skip the installation because `check_home()` will fail (no cluvfy binary).

---

## Part 3: Round 3 Deployment Strategy

### Why Pre-Copy Won't Work

Our original idea was to pre-copy software from the container image to hostPath before pod startup. This would NOT skip installation because:

1. **`check_home()` requires `cluvfy`** - This binary doesn't exist in the pre-built image
2. **`check_gi_installed()` requires `/etc/oracle`** - This directory doesn't exist in the pre-built image
3. **Both are created during Grid Infrastructure configuration**, not extraction

### Actual Strategy for Round 3

Since we cannot skip installation, our strategy is to **ensure installation succeeds** with adequate resources:

#### Resource Verification (Completed)

| Resource | ocne-w1 | ocne-w2 | Required |
|----------|---------|---------|----------|
| Disk Space | 70GB free | 53GB free | ~25GB |
| RAM | 23GB | 23GB | 16GB |
| Hugepages | Disabled | Disabled | - |
| SELinux | Permissive | Permissive | - |

#### Deployment Steps

1. **Install Oracle Database Operator** (if not already installed)
2. **Create RAC namespace with imagePullSecrets**
3. **Deploy RacDatabase CR** with proper configuration
4. **Monitor installation** - First pod (racnode1) will:
   - Extract Grid software to hostPath (~7.4GB)
   - Extract DB software to hostPath (~7.9GB)
   - Configure Grid Infrastructure
   - Create ASM disk groups
5. **Second pod (racnode2)** will:
   - Copy software from racnode1 via SSH/rsync
   - Join the cluster

### Future Optimization: Reusing Previous Installation

Once Round 3 succeeds, subsequent deployments CAN skip installation:

```
After successful Round 3:
├── /scratch/rac/cluster01/racnode1/
│   ├── app/19c/grid/bin/cluvfy     ← Created during config
│   └── app/grid/.etcoraclebackup/  ← Backup of /etc/oracle
└── /scratch/rac/cluster01/racnode2/
    └── (similar structure)

Future Round 4:
├── hostPath already populated
├── check_home() finds cluvfy → returns 0
├── check_gi_installed() finds /etc/oracle backup → returns True
└── GI_HOME_CONFIGURED_FLAG set → SKIPS installation!
```

**Important**: Don't clean up hostPath directories between rounds if you want to reuse the installation.

---

## Appendix: Useful Extraction Commands

### Search for specific patterns
```bash
# Find all environment variable checks
kubectl exec extract -n temp-extract -- bash -c \
  "grep -rn 'check_key.*FLAG' /opt/scripts/startup/scripts/*.py"

# Find all function definitions
kubectl exec extract -n temp-extract -- bash -c \
  "grep -n '^   def ' /opt/scripts/startup/scripts/oracommon.py | head -50"
```

### Extract multiple files at once
```bash
# Create local directory and copy key files
mkdir -p oracle-scripts
for f in main.py oracommon.py oragiprov.py oracvu.py orasetupenv.py; do
  kubectl cp temp-extract/extract:/opt/scripts/startup/scripts/$f ./oracle-scripts/$f
done
```

### Compare with previous versions
```bash
# Save current scripts
kubectl cp temp-extract/extract:/opt/scripts/startup/scripts/ ./scripts-19.23/

# Later, with different image version
kubectl cp temp-extract/extract:/opt/scripts/startup/scripts/ ./scripts-19.25/

# Compare
diff -r scripts-19.23 scripts-19.25
```

---

*Document Version: 1.0*
*Created: September 2026*
*Based on: Oracle RAC container image rac_ru:latest-19 (19.23)*
