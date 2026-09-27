#!/bin/bash
# restore-round1.sh
# Restores lab environment to Round 1 RAC snapshot
# Run from Git Bash / MINGW64

VBOX="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
SNAPSHOT="02-post-rac-round1"
ASM_BACKUP="/d/VMs/shared/round1"
ASM_PATH="/d/VMs/shared"

echo "=== Round 1 RAC Snapshot Restore ==="
echo "Snapshot: $SNAPSHOT"
echo "ASM Backup: $ASM_BACKUP"
echo ""

# Confirmation
read -p "This will restore all VMs and ASM disks to Round 1 state. Continue? (y/n) " confirm
if [ "$confirm" != "y" ]; then
    echo "Aborted."
    exit 1
fi

# Step 1: Power off all VMs
echo -e "\n[1/5] Powering off VMs..."
for vm in ocne-op ocne-cp1 ocne-w1 ocne-w2; do
    echo "  Powering off $vm..."
    "$VBOX" controlvm $vm poweroff 2>/dev/null
done
sleep 10

# Step 2: Restore snapshots
echo -e "\n[2/5] Restoring VM snapshots..."
for vm in ocne-op ocne-cp1 ocne-w1 ocne-w2; do
    echo "  Restoring $vm to $SNAPSHOT..."
    "$VBOX" snapshot $vm restore "$SNAPSHOT"
    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to restore $vm"
        exit 1
    fi
done

# Step 3: Restore ASM disks
echo -e "\n[3/5] Restoring ASM disks..."
if [ -f "$ASM_BACKUP/asm1.vdi" ]; then
    echo "  Copying asm1.vdi (41 GB)..."
    cp "$ASM_BACKUP/asm1.vdi" "$ASM_PATH/asm1.vdi"
    echo "  Copying asm2.vdi (41 GB)..."
    cp "$ASM_BACKUP/asm2.vdi" "$ASM_PATH/asm2.vdi"
    echo "  Copying asm3.vdi (21 GB)..."
    cp "$ASM_BACKUP/asm3.vdi" "$ASM_PATH/asm3.vdi"
else
    echo "  ERROR: ASM backup not found at $ASM_BACKUP"
    exit 1
fi

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
echo "  Starting ocne-op..."
"$VBOX" startvm ocne-op --type headless
echo "  Waiting 30 seconds..."
sleep 30

echo "  Starting ocne-cp1..."
"$VBOX" startvm ocne-cp1 --type headless
echo "  Waiting 30 seconds..."
sleep 30

echo "  Starting ocne-w1..."
"$VBOX" startvm ocne-w1 --type headless
echo "  Starting ocne-w2..."
"$VBOX" startvm ocne-w2 --type headless

echo -e "\n=== Restore Complete ==="
echo ""
echo "Wait 2-3 minutes for all services to start, then verify:"
echo "  ssh root@ocne-op 'kubectl get pods -n rac'"
echo "  ssh root@ocne-op 'kubectl get racdatabases -n rac'"
echo "  ssh root@ocne-op \"kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c \\\"srvctl status database -d RACDB\\\"'\""
