# Round 2 RAC Deployment - Issues and Fixes

This document captures the issues encountered during Round 2 RAC deployment and their solutions. Use this as a reference for Round 3 and future deployments.

---

## Issue 1: Image Pull Failure on Worker 2

### Symptom
```
disk-check-daemonset pod stuck in ImagePullBackOff on ocne-w2
```

### Error Message
```
Failed to pull image "container-registry.oracle.com/database/rac_ru:latest-19":
unable to retrieve auth token: invalid username/password: authentication required
```

### Root Cause
- The `disk-check-daemonset` created by the operator does NOT have `imagePullSecrets` configured
- Worker 1 had the image cached from Round 1
- Worker 2 did NOT have the image cached and couldn't pull without credentials

### Fix
Manually pull the image on the worker that doesn't have it cached:

```bash
# Get credentials from the secret
kubectl get secret oracle-container-registry-secret -n rac \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d

# SSH to the worker and pull manually
ssh root@ocne-w2 "crictl pull --creds 'username:password' \
  container-registry.oracle.com/database/rac_ru:latest-19"
```

### Prevention for Round 3
Before applying the RacDatabase manifest, verify the image is cached on ALL workers:

```bash
ssh root@ocne-w1 "crictl images | grep rac_ru"
ssh root@ocne-w2 "crictl images | grep rac_ru"
```

If missing, pre-pull on all workers before deployment.

---

## Issue 2: Pods Stuck in Pending - Insufficient Memory

### Symptom
```
kubectl get pods -n rac
NAME         READY   STATUS    AGE
racnode1-0   0/1     Pending   5m
racnode2-0   0/1     Pending   5m
```

### Error Message
```
Warning  FailedScheduling  pod/racnode1-0
0/3 nodes are available: 1 Insufficient memory, 1 node(s) didn't match Pod's
node affinity/selector, 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }
```

### Root Cause
The Oracle Database Operator requires **minimum 16GB memory limit** for RAC pods, but workers only had ~13.4GB allocatable.

**Memory breakdown:**
```
Worker VM total RAM:        20 GB
Hugepages reserved:          6 GB  (vm.nr_hugepages=3072 × 2MB)
System/kubelet reserved:   ~0.6 GB
Kubernetes allocatable:   ~13.4 GB  ← Less than required 16GB!
```

### Fix
Disable hugepages to free up 6GB of memory:

```bash
# On BOTH workers:
ssh root@ocne-w1 "sysctl -w vm.nr_hugepages=0"
ssh root@ocne-w2 "sysctl -w vm.nr_hugepages=0"

# Restart kubelet to update allocatable memory
ssh root@ocne-w1 "systemctl restart kubelet"
ssh root@ocne-w2 "systemctl restart kubelet"

# Verify new allocatable (should be ~19.5GB now)
kubectl describe node ocne-w1.lab.local | grep -A5 'Allocatable:'
```

**Result after fix:**
```
Before: memory: 13715760Ki (~13.4GB)
After:  memory: 20007216Ki (~19.5GB)  ✓ Enough for 16GB request
```

### Prevention for Round 3
Add this to the pre-flight checklist:

```bash
# Check hugepages setting
ssh root@ocne-w1 "sysctl vm.nr_hugepages"
ssh root@ocne-w2 "sysctl vm.nr_hugepages"

# If not 0, disable:
ssh root@ocne-w1 "sysctl -w vm.nr_hugepages=0"
ssh root@ocne-w2 "sysctl -w vm.nr_hugepages=0"

# Verify allocatable > 16GB
kubectl describe node ocne-w1.lab.local | grep 'memory:' | head -2
kubectl describe node ocne-w2.lab.local | grep 'memory:' | head -2
```

### Making Hugepages Change Persistent (Optional)
To survive reboots:

```bash
# On both workers:
echo "vm.nr_hugepages=0" >> /etc/sysctl.d/99-disable-hugepages.conf
sysctl -p /etc/sysctl.d/99-disable-hugepages.conf
```

---

## Issue 3: Container CrashLoopBackOff - SELinux Memory Protection

### Symptom
```
kubectl get pods -n rac
NAME         READY   STATUS             RESTARTS   AGE
racnode1-0   0/1     CrashLoopBackOff   3          2m
racnode2-0   0/1     Running            0          2m
```

### Error Message
```
kubectl logs racnode1-0 -n rac
/usr/sbin/init: error while loading shared libraries: libseccomp.so.2:
cannot change memory protections
```

### Root Cause
- SELinux in **Enforcing** mode blocks memory protection changes
- The Oracle RAC container uses glibc features that require relaxed memory protection
- The main RAC container runs with `privileged: false` (set by operator)
- This is a known compatibility issue with Oracle containers on Oracle Linux 9.x with SELinux

### Fix
Set SELinux to Permissive mode on both workers:

```bash
# On BOTH workers:
ssh root@ocne-w1 "setenforce 0"
ssh root@ocne-w2 "setenforce 0"

# Verify
ssh root@ocne-w1 "getenforce"  # Should show: Permissive
ssh root@ocne-w2 "getenforce"  # Should show: Permissive

# Delete pods to restart with new SELinux setting
kubectl delete pod racnode1-0 racnode2-0 -n rac
```

### Prevention for Round 3
Add to pre-flight checklist:

```bash
# Check SELinux mode
ssh root@ocne-w1 "getenforce"
ssh root@ocne-w2 "getenforce"

# If Enforcing, set to Permissive:
ssh root@ocne-w1 "setenforce 0"
ssh root@ocne-w2 "setenforce 0"
```

### Making SELinux Change Persistent (Optional)
To survive reboots:

```bash
# On both workers:
sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

---

## Issue 4: CRD Validation Requires Software Staging Parameters

### Symptom
```
kubectl apply -f racdb-round2.yaml
The RacDatabase "racdb01" is invalid:
* spec.ConfigParams.GridSwZipFile: Invalid value: "": GridSwZipFile cannot be set empty
* spec.ConfigParams.DbSwZipFile: Invalid value: "": DbSwZipFile cannot be set empty
```

### Root Cause
Even though the `rac_ru:latest-19` image has binaries pre-installed, the Oracle Database Operator CRD **requires** these fields for validation:
- `hostSwStageLocation`
- `gridSwZipFile`
- `dbSwZipFile`

### Fix
Include these required fields in the manifest, even though they won't be used:

```yaml
configParams:
  # ... other params ...

  # Required by CRD validation (binaries already in image, won't extract)
  hostSwStageLocation: "/scratch/software/stage"
  gridSwZipFile: "LINUX.X64_193000_grid_home.zip"
  dbSwZipFile: "LINUX.X64_193000_db_home.zip"

  # OMIT these to avoid redundant patching (image already has 19.32):
  # ruPatchLocation: "..."
  # oPatchLocation: "..."
```

### Key Insight
The optimization is **omitting `ruPatchLocation` and `oPatchLocation`**, NOT omitting the software staging paths. The staging paths are required by the CRD schema but are not used when the image already contains the binaries.

---

## Complete Pre-Flight Checklist for Round 3

Based on Round 2 learnings, run these checks BEFORE applying the RacDatabase manifest:

```bash
#!/bin/bash
# Round 3 Pre-Flight Checklist

echo "=== 1. Check VMs Running ==="
VBoxManage list runningvms

echo "=== 2. Check Kubernetes Nodes ==="
kubectl get nodes

echo "=== 3. Check Operator Running ==="
kubectl get pods -n oracle-database-operator-system

echo "=== 4. Check RAC Image Cached on Workers ==="
ssh root@ocne-w1 "crictl images | grep rac_ru"
ssh root@ocne-w2 "crictl images | grep rac_ru"

echo "=== 5. Check Hugepages Disabled ==="
ssh root@ocne-w1 "sysctl vm.nr_hugepages"
ssh root@ocne-w2 "sysctl vm.nr_hugepages"
# Should be 0

echo "=== 6. Check Memory Allocatable > 16GB ==="
kubectl describe node ocne-w1.lab.local | grep -A1 'Allocatable:'
kubectl describe node ocne-w2.lab.local | grep -A1 'Allocatable:'

echo "=== 7. Check SELinux Permissive ==="
ssh root@ocne-w1 "getenforce"
ssh root@ocne-w2 "getenforce"
# Should be Permissive

echo "=== 8. Check Promiscuous Mode ==="
ssh root@ocne-w1 "ip link show enp0s8 | grep PROMISC"
ssh root@ocne-w2 "ip link show enp0s8 | grep PROMISC"

echo "=== 9. Check ASM Disks ==="
ssh root@ocne-w1 "ls -la /dev/sd[cd]"
ssh root@ocne-w2 "ls -la /dev/sd[cd]"

echo "=== 10. Check Secrets Exist ==="
kubectl get secrets -n rac

echo "=== 11. Check NADs Exist ==="
kubectl get net-attach-def -n rac

echo "=== 12. Check Worker Labels ==="
kubectl get nodes -l raccluster=raccluster01
```

---

## Summary Table

| Issue | Symptom | Fix | Time Impact |
|-------|---------|-----|-------------|
| Image not cached | ImagePullBackOff | Pre-pull on workers | ~10 min |
| Hugepages enabled | Pending (Insufficient memory) | `sysctl -w vm.nr_hugepages=0` | ~2 min |
| SELinux Enforcing | CrashLoopBackOff | `setenforce 0` | ~1 min |
| Missing CRD fields | Validation error | Add required fields | ~1 min |

---

*Document Version: 1.0*
*Created: September 2026*
*Based on: Round 2 Deployment Experience*
