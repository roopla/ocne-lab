# Round 2 RAC Deployment - Pre-Flight Checklist

## Quick Summary

**Goal:** Deploy RAC faster by avoiding redundant patching
**Expected Time:** ~1-2 hours (vs ~4-5 hours in Round 1)
**Key Change:** Omit `ruPatchLocation` since image already has 19.32 RU

---

## Pre-Flight Checklist

### 1. Start VMs

```powershell
# PowerShell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm ocne-op --type headless
Start-Sleep -Seconds 30
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm ocne-cp1 --type headless
Start-Sleep -Seconds 30
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm ocne-w1 --type headless
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm ocne-w2 --type headless
```

Or Bash:
```bash
"/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" startvm ocne-op --type headless
sleep 30
"/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" startvm ocne-cp1 --type headless
sleep 30
"/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" startvm ocne-w1 --type headless
"/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" startvm ocne-w2 --type headless
```

### 2. Verify Cluster Health

```bash
# Wait 2-3 minutes, then:
ssh root@ocne-op "kubectl get nodes"
```

**Expected:**
```
NAME                 STATUS   ROLES           AGE    VERSION
ocne-cp1.lab.local   Ready    control-plane   7d     v1.29.14+2.el9
ocne-w1.lab.local    Ready    worker          7d     v1.29.14+2.el9
ocne-w2.lab.local    Ready    worker          7d     v1.29.14+2.el9
```

### 3. Verify Operator is Running

```bash
ssh root@ocne-op "kubectl get pods -n oracle-database-operator-system"
```

**Expected:** All 3 pods Running

### 4. Verify Secrets Exist

```bash
ssh root@ocne-op "kubectl get secrets -n rac"
```

**Expected:**
```
NAME                                TYPE                             DATA   AGE
db-user-pass-pkutl                  Opaque                           2      ...
oracle-container-registry-secret    kubernetes.io/dockerconfigjson   1      ...
ssh-key-secret                      Opaque                           2      ...
```

### 5. Verify ASM Disks on Workers

```bash
ssh root@ocne-w1 "ls -la /dev/sd[cd]"
ssh root@ocne-w2 "ls -la /dev/sd[cd]"
```

**Expected:** `/dev/sdc` and `/dev/sdd` present (20GB each)

### 6. Verify Worker Node Labels

```bash
ssh root@ocne-op "kubectl get nodes --show-labels | grep raccluster"
```

**Expected:** Both workers labeled `raccluster=raccluster01`

### 7. Verify Network Attachment Definitions

```bash
ssh root@ocne-op "kubectl get net-attach-def -n rac"
```

**Expected:**
```
NAME        AGE
rac-priv1   ...
rac-priv2   ...
```

If missing, recreate:
```bash
ssh root@ocne-op 'cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: rac-priv1
  namespace: rac
spec:
  config: '\''{"cniVersion": "0.3.1", "type": "macvlan", "master": "enp0s8", "mode": "bridge", "ipam": {"type": "static"}}'\''
EOF'

ssh root@ocne-op 'cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: rac-priv2
  namespace: rac
spec:
  config: '\''{"cniVersion": "0.3.1", "type": "macvlan", "master": "enp0s9", "mode": "bridge", "ipam": {"type": "static"}}'\''
EOF'
```

### 8. Verify Promiscuous Mode on Workers

```bash
ssh root@ocne-w1 "ip link show enp0s8 | grep PROMISC"
ssh root@ocne-w1 "ip link show enp0s9 | grep PROMISC"
ssh root@ocne-w2 "ip link show enp0s8 | grep PROMISC"
ssh root@ocne-w2 "ip link show enp0s9 | grep PROMISC"
```

If not showing PROMISC, enable:
```bash
ssh root@ocne-w1 "ip link set enp0s8 promisc on && ip link set enp0s9 promisc on"
ssh root@ocne-w2 "ip link set enp0s8 promisc on && ip link set enp0s9 promisc on"
```

---

## Deploy RAC (Round 2)

### Option A: Use Optimized YAML

```bash
# Copy optimized yaml to operator node (from repo root)
scp configs/racdb-round2.yaml root@ocne-op:/root/

# Deploy
ssh root@ocne-op "kubectl apply -f /root/racdb-round2.yaml"
```

### Option B: Apply Directly

```bash
ssh root@ocne-op 'kubectl apply -f - <<EOF
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
    pdbName: "ORCLPDB"
    dbCharSet: "AL32UTF8"
    # NO ruPatchLocation - image already has 19.32 RU!
    # NO oPatchLocation - saves ~2-3 hours!
EOF'
```

---

## Monitor Deployment

### Watch Pod Creation
```bash
ssh root@ocne-op "kubectl get pods -n rac -w"
```

### Check RAC Database Status
```bash
ssh root@ocne-op "kubectl get racdatabases -n rac"
```

### Follow Deployment Logs
```bash
# Wait for pods to start, then:
ssh root@ocne-op "kubectl logs -f racnode1-0 -n rac -c racnode1-0"

# Or check detailed log inside pod:
ssh root@ocne-op "kubectl exec -it racnode1-0 -n rac -- tail -f /tmp/orod/oracle_db_setup.log"
```

---

## Expected Timeline (Round 2)

| Phase | Duration | Notes |
|-------|----------|-------|
| Pod creation | ~5 min | Image pull if not cached |
| Grid setup | ~20-40 min | NO patching this time! |
| root.sh (both nodes) | ~10-20 min | |
| Database creation (dbca) | ~30-60 min | |
| **Total** | **~1-2 hours** | vs 4-5 hours in Round 1 |

---

## Verification Commands

### After Deployment Complete

```bash
# Check cluster
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"crsctl check cluster -all\"'"

# Check database
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"srvctl status database -d RACDB -v\"'"

# Check ASM
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"srvctl status asm\"'"

# Full resource status
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"crsctl stat res -t\"'"
```

---

## Troubleshooting

### If pods stuck in Init
```bash
ssh root@ocne-op "kubectl describe pod racnode1-0 -n rac"
ssh root@ocne-op "kubectl logs racnode1-0 -n rac -c racnode1-init1"
```

### If ASM disk issues
```bash
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- ls -la /dev/sd*"
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- cat /etc/orod/asm_device_list"
```

### If network issues
```bash
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- ip addr show"
```

---

## Round 1 vs Round 2 Comparison

| Aspect | Round 1 | Round 2 |
|--------|---------|---------|
| Image | rac_ru:latest-19 | rac_ru:latest-19 (same) |
| ruPatchLocation | Specified (19.32) | **OMITTED** |
| oPatchLocation | Specified | **OMITTED** |
| ASM disks | 3 x 20GB | 2 x 20GB |
| Patching time | ~2-3 hours (redundant) | **0** (skipped) |
| Total time | ~4-5 hours | ~1-2 hours |

---

*Created: September 2026*
*Ready for Round 2 deployment*
