# restore-round1.ps1
# Restores lab environment to Round 1 RAC snapshot
# Run from PowerShell as Administrator

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$VMs = @("ocne-op", "ocne-cp1", "ocne-w1", "ocne-w2")
$SnapshotName = "02-post-rac-round1"
$ASMBackupPath = "D:\VMs\shared\round1"
$ASMPath = "D:\VMs\shared"

Write-Host "=== Round 1 RAC Snapshot Restore ===" -ForegroundColor Cyan
Write-Host "Snapshot: $SnapshotName"
Write-Host "ASM Backup: $ASMBackupPath"
Write-Host ""

# Confirmation
$confirm = Read-Host "This will restore all VMs and ASM disks to Round 1 state. Continue? (y/n)"
if ($confirm -ne "y") {
    Write-Host "Aborted." -ForegroundColor Red
    exit 1
}

# Step 1: Power off all VMs
Write-Host "`n[1/5] Powering off VMs..." -ForegroundColor Yellow
foreach ($vm in $VMs) {
    $running = & $VBoxManage list runningvms 2>$null | Select-String $vm
    if ($running) {
        Write-Host "  Powering off $vm..."
        & $VBoxManage controlvm $vm poweroff 2>$null
        Start-Sleep -Seconds 5
    } else {
        Write-Host "  $vm already off"
    }
}
Start-Sleep -Seconds 5

# Step 2: Restore snapshots
Write-Host "`n[2/5] Restoring VM snapshots..." -ForegroundColor Yellow
foreach ($vm in $VMs) {
    Write-Host "  Restoring $vm to $SnapshotName..."
    & $VBoxManage snapshot $vm restore $SnapshotName
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to restore $vm" -ForegroundColor Red
        exit 1
    }
}

# Step 3: Restore ASM disks
Write-Host "`n[3/5] Restoring ASM disks..." -ForegroundColor Yellow
if (Test-Path "$ASMBackupPath\asm1.vdi") {
    Write-Host "  Copying asm1.vdi (41 GB)..."
    Copy-Item "$ASMBackupPath\asm1.vdi" "$ASMPath\asm1.vdi" -Force
    Write-Host "  Copying asm2.vdi (41 GB)..."
    Copy-Item "$ASMBackupPath\asm2.vdi" "$ASMPath\asm2.vdi" -Force
    Write-Host "  Copying asm3.vdi (21 GB)..."
    Copy-Item "$ASMBackupPath\asm3.vdi" "$ASMPath\asm3.vdi" -Force
} else {
    Write-Host "  ERROR: ASM backup not found at $ASMBackupPath" -ForegroundColor Red
    exit 1
}

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
Write-Host "  Waiting 30 seconds..."
Start-Sleep -Seconds 30

Write-Host "  Starting ocne-cp1..."
& $VBoxManage startvm ocne-cp1 --type headless
Write-Host "  Waiting 30 seconds..."
Start-Sleep -Seconds 30

Write-Host "  Starting ocne-w1..."
& $VBoxManage startvm ocne-w1 --type headless
Write-Host "  Starting ocne-w2..."
& $VBoxManage startvm ocne-w2 --type headless

Write-Host "`n=== Restore Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Wait 2-3 minutes for all services to start, then verify:" -ForegroundColor Cyan
Write-Host "  ssh root@ocne-op 'kubectl get pods -n rac'"
Write-Host "  ssh root@ocne-op 'kubectl get racdatabases -n rac'"
Write-Host "  ssh root@ocne-op `"kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \`"srvctl status database -d RACDB\`"'`""
