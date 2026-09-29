# Checking Oracle Container Image Patch Levels

This document explains how to inspect Oracle RAC container images to verify their patch levels before deployment.

---

## Why Check Patch Levels?

Oracle provides two types of RAC container images:

| Image | Description | Patch Status |
|-------|-------------|--------------|
| `rac:latest` | Base image | 19.3.0.0.0 (requires patching) |
| `rac_ru:latest-19` | Release Update image | Pre-patched (19.32+) |

**Critical Decision:** If the image already has Release Update patches applied, you should **NOT** specify `ruPatchLocation` in your RacDatabase manifest. Doing so causes redundant patching operations that add 2-3 hours to deployment.

---

## Step 1: Start a Test Container

Oracle containers require privileged mode due to SELinux restrictions on Oracle Linux 9.x.

### Command

```bash
# SSH to the operator node (or any node with kubectl access)
ssh root@ocne-op

# Run a temporary privileged container
kubectl run patch-check --rm -it --restart=Never \
  --image=container-registry.oracle.com/database/rac_ru:latest-19 \
  --image-pull-policy=IfNotPresent \
  --privileged=true \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"oracle-container-registry-secret"}]}}' \
  -n rac \
  -- /bin/bash
```

### Explanation of Parameters

| Parameter | Purpose |
|-----------|---------|
| `--rm` | Automatically delete the pod when you exit |
| `-it` | Interactive mode with TTY (allows shell interaction) |
| `--restart=Never` | Don't restart if the container exits (one-time run) |
| `--image=...` | The Oracle RAC image to inspect |
| `--image-pull-policy=IfNotPresent` | Use cached image if available (saves time) |
| `--privileged=true` | Required for Oracle containers on SELinux-enabled hosts |
| `--overrides=...` | Inject imagePullSecrets for Oracle Container Registry authentication |
| `-n rac` | Run in the `rac` namespace (where the secret exists) |
| `-- /bin/bash` | Command to run inside the container |

### What Happens

1. Kubernetes creates a pod named `patch-check` in the `rac` namespace
2. The container starts with systemd (you'll see service startup messages)
3. You get an interactive bash shell inside the container
4. When you exit, the pod is automatically deleted

### If You Don't See a Prompt

The container runs systemd which may delay the prompt. Try:
- Press Enter multiple times
- Type commands directly (they will execute)
- Or connect from another terminal:
  ```bash
  ssh root@ocne-op "kubectl exec -it patch-check -n rac -- /bin/bash"
  ```

---

## Step 2: Check Grid Infrastructure Patches

OPatch cannot run as root. You must switch to the `grid` user.

### Commands

```bash
# Switch to grid user
su - grid

# Verify you're the grid user
id
# Expected: uid=54332(grid) gid=54321(oinstall) groups=54321(oinstall),54322(dba),...

# Navigate to OPatch directory
cd /u01/app/19c/grid/OPatch

# List all applied patches
./opatch lspatches

# Check OPatch version
./opatch version
```

### Example Output

```
39526364;OCW RELEASE UPDATE 19.32.0.0.0 (39526364)
39503034;ACFS RELEASE UPDATE 19.32.0.0.0 (39503034)
39472050;Database Release Update : 19.32.0.0.260721 (39472050)
39107855;TOMCAT RELEASE UPDATE 19.0.0.0.0 (39107855)
39107825;DBWLM RELEASE UPDATE 19.0.0.0.0 (39107825)

OPatch succeeded.
```

### Understanding the Output

| Patch ID | Component | Version | Significance |
|----------|-----------|---------|--------------|
| 39472050 | Database RU | 19.32.0.0.260721 | **Main Release Update** - this is the key patch |
| 39526364 | OCW | 19.32.0.0.0 | Oracle Clusterware components |
| 39503034 | ACFS | 19.32.0.0.0 | ASM Cluster File System |
| 39107855 | TOMCAT | 19.0.0.0.0 | Web server components |
| 39107825 | DBWLM | 19.0.0.0.0 | Workload Management |

The **Database Release Update (39472050)** is the critical one. The version `19.32.0.0.260721` indicates:
- 19 = Major version (Oracle 19c)
- 32 = Release Update number (32nd quarterly update)
- 0.0 = Platform-specific revision
- 260721 = Date code (July 21, 2026)

---

## Step 3: Check Database Home Patches

Switch to the `oracle` user to check the database home.

### Commands

```bash
# If still as grid user, exit first
exit

# Switch to oracle user
su - oracle

# Navigate to Database Home OPatch
cd /u01/app/oracle/product/19c/dbhome_1/OPatch

# List all applied patches
./opatch lspatches

# Check OPatch version
./opatch version
```

### Example Output

```
39526364;OCW RELEASE UPDATE 19.32.0.0.0 (39526364)
39472050;Database Release Update : 19.32.0.0.260721 (39472050)

OPatch succeeded.
```

---

## Step 4: Exit the Container

```bash
# Exit from oracle user
exit

# Exit from the container (pod will be auto-deleted)
exit
```

You should see:
```
pod "patch-check" deleted
```

---

## Common Errors and Solutions

### Error: "OPatch cannot continue if the user is root"

```
The user is root. OPatch cannot continue if the user is root.
OPatch failed with error code 255
```

**Solution:** Switch to the appropriate user:
- For Grid Home: `su - grid`
- For Database Home: `su - oracle`

### Error: "cannot apply additional memory protection after relocation"

```
/bin/sh: error while loading shared libraries: /lib64/libc.so.6:
cannot apply additional memory protection after relocation: Permission denied
```

**Solution:** Add `--privileged=true` to the kubectl run command. This is required because Oracle containers use memory protection features that SELinux blocks by default.

### Error: "No such file or directory" for OPatch

**Solution:** Verify the correct paths:
- Grid Home: `/u01/app/19c/grid/OPatch/opatch`
- DB Home: `/u01/app/oracle/product/19c/dbhome_1/OPatch/opatch`

Note: It's `dbhome_1` (with underscore), not `dbhome1`.

---

## Quick Reference: Oracle Home Paths

| Component | Path |
|-----------|------|
| Grid Home | `/u01/app/19c/grid` |
| Grid Base | `/u01/app/grid` |
| Database Home | `/u01/app/oracle/product/19c/dbhome_1` |
| Oracle Base | `/u01/app/oracle` |
| Inventory | `/u01/app/oraInventory` |
| OPatch (Grid) | `/u01/app/19c/grid/OPatch/opatch` |
| OPatch (DB) | `/u01/app/oracle/product/19c/dbhome_1/OPatch/opatch` |

---

## Quick Reference: Oracle Users

| User | UID | Primary Group | Purpose |
|------|-----|---------------|---------|
| grid | 54332 | oinstall (54321) | Grid Infrastructure owner |
| oracle | 54321 | oinstall (54321) | Database software owner |

---

## Decision Matrix: When to Specify ruPatchLocation

| Image Used | Patches in Image | Specify ruPatchLocation? | Result |
|------------|------------------|--------------------------|--------|
| `rac:latest` | 19.3.0.0.0 (base) | **YES** | Patches applied during deployment |
| `rac_ru:latest-19` | 19.32.0.0.0 | **NO** | Skip patching, saves 2-3 hours |
| `rac_ru:latest-19` | 19.32.0.0.0 | YES (same version) | Redundant patching, wastes time |
| `rac_ru:latest-19` | 19.32.0.0.0 | YES (newer version) | Apply newer patches on top |

---

## Alternative: Check Without Interactive Shell

If you just want to see the patch list without an interactive session:

```bash
kubectl run patch-check --rm -it --restart=Never \
  --image=container-registry.oracle.com/database/rac_ru:latest-19 \
  --image-pull-policy=IfNotPresent \
  --privileged=true \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"oracle-container-registry-secret"}]}}' \
  -n rac \
  -- /bin/bash -c "su - grid -c '/u01/app/19c/grid/OPatch/opatch lspatches'"
```

This runs the command and exits automatically.

---

## Summary

1. Start privileged test container with `kubectl run --privileged=true`
2. Switch to `grid` user for Grid Home patches
3. Switch to `oracle` user for Database Home patches
4. Run `./opatch lspatches` to see applied patches
5. Look for "Database Release Update 19.32.0.0.0" to confirm pre-patched image
6. Exit container (auto-deleted with `--rm`)

**Key Takeaway:** The `rac_ru:latest-19` image has 19.32.0.0.0 patches pre-applied. Omit `ruPatchLocation` from your RacDatabase manifest to avoid redundant patching.

---

*Document Version: 1.0*
*Created: September 2026*
*Verified on: rac_ru:latest-19 image*
