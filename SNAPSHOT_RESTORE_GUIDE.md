# Snapshot Restore Guide

This guide documents how to restore the lab environment to specific snapshot points.

## Available Snapshots

| Snapshot Name | Description | Date |
|---------------|-------------|------|
| `01-ocne-base` | OCNE 1.9 cluster up, no operator yet | Initial |
| `02-post-rac-round1` | After RAC Phase C completion, before round 2 cleanup | Sept 2026 |

## Round 1 RAC Snapshot Details

**Snapshot:** `02-post-rac-round1`

**What's preserved:**
- All 4 VMs (ocne-op, ocne-cp1, ocne-w1, ocne-w2)
- Oracle Database Operator installed
- RAC deployment completed (RACDB with ORCLPDB)
- All Kubernetes resources in `rac` namespace

**ASM Disk Backup Location:** `D:\VMs\shared\round1\`
- `asm1.vdi` (41 GB)
- `asm2.vdi` (41 GB)
- `asm3.vdi` (21 GB)

---

## Restore Procedure

### Prerequisites

- All VMs must be powered off before restore
- VirtualBox installed at `C:\Program Files\Oracle\VirtualBox`

### Step 1: Power Off All VMs (if running)

```powershell
# PowerShell - Check running VMs
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" list runningvms

# Power off each running VM
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm ocne-op poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm ocne-cp1 poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm ocne-w1 poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm ocne-w2 poweroff
```

### Step 2: Restore VM Snapshots

```powershell
# Restore all VMs to Round 1 snapshot
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" snapshot ocne-op restore "02-post-rac-round1"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" snapshot ocne-cp1 restore "02-post-rac-round1"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" snapshot ocne-w1 restore "02-post-rac-round1"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" snapshot ocne-w2 restore "02-post-rac-round1"
```

### Step 3: Restore ASM Disks

```powershell
# Copy backed up ASM disks back to shared location
Copy-Item "D:\VMs\shared\round1\asm1.vdi" "D:\VMs\shared\asm1.vdi" -Force
Copy-Item "D:\VMs\shared\round1\asm2.vdi" "D:\VMs\shared\asm2.vdi" -Force
Copy-Item "D:\VMs\shared\round1\asm3.vdi" "D:\VMs\shared\asm3.vdi" -Force
```

### Step 4: Reattach ASM Disks to Workers

```powershell
# Attach ASM disks to ocne-w1
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storageattach ocne-w1 --storagectl SATA --port 2 --device 0 --type hdd --medium "D:\VMs\shared\asm1.vdi" --mtype shareable
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storageattach ocne-w1 --storagectl SATA --port 3 --device 0 --type hdd --medium "D:\VMs\shared\asm2.vdi" --mtype shareable
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storageattach ocne-w1 --storagectl SATA --port 4 --device 0 --type hdd --medium "D:\VMs\shared\asm3.vdi" --mtype shareable

# Attach ASM disks to ocne-w2
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storageattach ocne-w2 --storagectl SATA --port 2 --device 0 --type hdd --medium "D:\VMs\shared\asm1.vdi" --mtype shareable
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storageattach ocne-w2 --storagectl SATA --port 3 --device 0 --type hdd --medium "D:\VMs\shared\asm2.vdi" --mtype shareable
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storageattach ocne-w2 --storagectl SATA --port 4 --device 0 --type hdd --medium "D:\VMs\shared\asm3.vdi" --mtype shareable
```

### Step 5: Start VMs

```powershell
# Start VMs in order: operator -> control plane -> workers
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm ocne-op --type headless
Start-Sleep -Seconds 30

& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm ocne-cp1 --type headless
Start-Sleep -Seconds 30

& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm ocne-w1 --type headless
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm ocne-w2 --type headless
```

### Step 6: Verify RAC Status

Wait 2-3 minutes for all services to start, then:

```bash
# SSH to operator node and check RAC status
ssh root@ocne-op "kubectl get pods -n rac"
ssh root@ocne-op "kubectl get racdatabases -n rac"

# Check cluster status
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"crsctl check cluster -all\"'"

# Check database status
ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"srvctl status database -d RACDB -v\"'"
```

---

## Complete Restore Script (PowerShell)

Save as `restore-round1.ps1`:

```powershell
# restore-round1.ps1
# Restores lab environment to Round 1 RAC snapshot

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$VMs = @("ocne-op", "ocne-cp1", "ocne-w1", "ocne-w2")
$SnapshotName = "02-post-rac-round1"
$ASMBackupPath = "D:\VMs\shared\round1"
$ASMPath = "D:\VMs\shared"

Write-Host "=== Round 1 RAC Snapshot Restore ===" -ForegroundColor Cyan

# Step 1: Power off all VMs
Write-Host "`n[1/5] Powering off VMs..." -ForegroundColor Yellow
foreach ($vm in $VMs) {
    $running = & $VBoxManage list runningvms | Select-String $vm
    if ($running) {
        Write-Host "  Powering off $vm..."
        & $VBoxManage controlvm $vm poweroff 2>$null
        Start-Sleep -Seconds 5
    }
}

# Step 2: Restore snapshots
Write-Host "`n[2/5] Restoring VM snapshots..." -ForegroundColor Yellow
foreach ($vm in $VMs) {
    Write-Host "  Restoring $vm to $SnapshotName..."
    & $VBoxManage snapshot $vm restore $SnapshotName
}

# Step 3: Restore ASM disks
Write-Host "`n[3/5] Restoring ASM disks..." -ForegroundColor Yellow
Copy-Item "$ASMBackupPath\asm1.vdi" "$ASMPath\asm1.vdi" -Force
Write-Host "  Copied asm1.vdi"
Copy-Item "$ASMBackupPath\asm2.vdi" "$ASMPath\asm2.vdi" -Force
Write-Host "  Copied asm2.vdi"
Copy-Item "$ASMBackupPath\asm3.vdi" "$ASMPath\asm3.vdi" -Force
Write-Host "  Copied asm3.vdi"

# Step 4: Reattach ASM disks
Write-Host "`n[4/5] Reattaching ASM disks..." -ForegroundColor Yellow
$workers = @("ocne-w1", "ocne-w2")
foreach ($worker in $workers) {
    Write-Host "  Attaching disks to $worker..."
    & $VBoxManage storageattach $worker --storagectl SATA --port 2 --device 0 --type hdd --medium "$ASMPath\asm1.vdi" --mtype shareable
    & $VBoxManage storageattach $worker --storagectl SATA --port 3 --device 0 --type hdd --medium "$ASMPath\asm2.vdi" --mtype shareable
    & $VBoxManage storageattach $worker --storagectl SATA --port 4 --device 0 --type hdd --medium "$ASMPath\asm3.vdi" --mtype shareable
}

# Step 5: Start VMs
Write-Host "`n[5/5] Starting VMs..." -ForegroundColor Yellow
Write-Host "  Starting ocne-op..."
& $VBoxManage startvm ocne-op --type headless
Start-Sleep -Seconds 30

Write-Host "  Starting ocne-cp1..."
& $VBoxManage startvm ocne-cp1 --type headless
Start-Sleep -Seconds 30

Write-Host "  Starting ocne-w1..."
& $VBoxManage startvm ocne-w1 --type headless
Write-Host "  Starting ocne-w2..."
& $VBoxManage startvm ocne-w2 --type headless

Write-Host "`n=== Restore Complete ===" -ForegroundColor Green
Write-Host "Wait 2-3 minutes for services to start, then verify with:"
Write-Host "  ssh root@ocne-op 'kubectl get pods -n rac'"
Write-Host "  ssh root@ocne-op 'kubectl get racdatabases -n rac'"
```

---

## Bash Version (Git Bash / MINGW64)

Save as `restore-round1.sh`:

```bash
#!/bin/bash
# restore-round1.sh
# Restores lab environment to Round 1 RAC snapshot

VBOX="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
SNAPSHOT="02-post-rac-round1"
ASM_BACKUP="/d/VMs/shared/round1"
ASM_PATH="/d/VMs/shared"

echo "=== Round 1 RAC Snapshot Restore ==="

# Step 1: Power off all VMs
echo -e "\n[1/5] Powering off VMs..."
for vm in ocne-op ocne-cp1 ocne-w1 ocne-w2; do
    "$VBOX" controlvm $vm poweroff 2>/dev/null
done
sleep 10

# Step 2: Restore snapshots
echo -e "\n[2/5] Restoring VM snapshots..."
for vm in ocne-op ocne-cp1 ocne-w1 ocne-w2; do
    echo "  Restoring $vm..."
    "$VBOX" snapshot $vm restore "$SNAPSHOT"
done

# Step 3: Restore ASM disks
echo -e "\n[3/5] Restoring ASM disks..."
cp "$ASM_BACKUP/asm1.vdi" "$ASM_PATH/asm1.vdi"
cp "$ASM_BACKUP/asm2.vdi" "$ASM_PATH/asm2.vdi"
cp "$ASM_BACKUP/asm3.vdi" "$ASM_PATH/asm3.vdi"

# Step 4: Reattach ASM disks
echo -e "\n[4/5] Reattaching ASM disks..."
for worker in ocne-w1 ocne-w2; do
    echo "  Attaching disks to $worker..."
    "$VBOX" storageattach $worker --storagectl SATA --port 2 --device 0 --type hdd --medium "$ASM_PATH/asm1.vdi" --mtype shareable
    "$VBOX" storageattach $worker --storagectl SATA --port 3 --device 0 --type hdd --medium "$ASM_PATH/asm2.vdi" --mtype shareable
    "$VBOX" storageattach $worker --storagectl SATA --port 4 --device 0 --type hdd --medium "$ASM_PATH/asm3.vdi" --mtype shareable
done

# Step 5: Start VMs
echo -e "\n[5/5] Starting VMs..."
"$VBOX" startvm ocne-op --type headless
sleep 30
"$VBOX" startvm ocne-cp1 --type headless
sleep 30
"$VBOX" startvm ocne-w1 --type headless
"$VBOX" startvm ocne-w2 --type headless

echo -e "\n=== Restore Complete ==="
echo "Wait 2-3 minutes, then verify with:"
echo "  ssh root@ocne-op 'kubectl get pods -n rac'"
```

---

## Troubleshooting

### ASM disk attachment fails

If you get "medium already attached" error:
```powershell
# First close the medium
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" closemedium disk "D:\VMs\shared\asm1.vdi"
# Then reattach
```

### VMs won't start after restore

Check if disks are properly attached:
```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" showvminfo ocne-w1 | Select-String "SATA"
```

### RAC not starting after restore

1. Check if CRS is running:
   ```bash
   ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \"crsctl check crs\"'"
   ```

2. If CRS is offline, start it manually:
   ```bash
   ssh root@ocne-op "kubectl exec racnode1-0 -n rac -- bash -c 'su - root -c \"/u01/app/19c/grid/bin/crsctl start crs\"'"
   ```

---

*Document Version: 1.0*
*Created: September 2026*
