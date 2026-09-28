# Complete OCNE + Oracle Database Operator Lab Setup Guide

This guide consolidates all setup steps from VM creation through database deployment.
Follow phases in order - each builds on the previous.

---

## Prerequisites

### Hardware Requirements
| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 50 GB allocated to VMs | 64 GB total system |
| CPU | 22 logical processors for VMs | 26+ logical processors |
| Disk | 400 GB free | 500 GB+ SSD |
| Network | Wired Ethernet (USB adapter OK) | Gigabit |

### Software Requirements
- Windows 10/11 (Hyper-V disabled)
- Oracle VirtualBox 7.x + Extension Pack
- Oracle Linux 9.8 DVD ISO
- Oracle Grid Infrastructure 19.3.0 (`LINUX.X64_193000_grid_home.zip`)
- Oracle Database 19.3.0 (`LINUX.X64_193000_db_home.zip`)
- Oracle patches from MOS (for RU 19.28+): 37957391, 38336965, 34436514, 6880880

### Oracle Container Registry
1. Sign in at `container-registry.oracle.com`
2. Accept license for `database/enterprise` image
3. Note credentials for image pull secrets

---

## Phase Overview

| Phase | Description | Time Estimate | Reference |
|-------|-------------|---------------|-----------|
| 0 | Windows host preparation | 30 min | runbook.md |
| 1 | Download media | 2-4 hours (download) | runbook.md |
| 2 | Build golden VM | 1 hour | runbook.md |
| 3 | Clone and configure 4 VMs | 1 hour | runbook.md |
| 4 | Storage setup | 30 min | runbook.md |
| 5 | Install OCNE 1.9 | 20-30 min | runbook.md |
| 6 | Install Operator + Multus | 15 min | runbook.md |
| A | SIDB + Data Guard | 2-3 hours | phase-a-sidb-dataguard-setup.md |
| B | Oracle Restart + ASM | 3-4 hours | phase-b-oracle-restart-asm-setup.md |

---

## Phase 0: Windows Host Preparation

**Goal:** Disable Hyper-V, install VirtualBox, prepare folder structure.

### Step 0.1: Disable Hyper-V Stack
```powershell
# Run as Administrator
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart

bcdedit /set hypervisorlaunchtype off
```

### Step 0.2: Disable Memory Integrity
Settings → Privacy & security → Windows Security → Device security → Core isolation → **Memory integrity: Off**

**Reboot Windows**

### Step 0.3: Verify Hyper-V Disabled
```powershell
systeminfo | Select-String "Hyper-V"
# Should show virtualization requirements as "Yes" but NO hypervisor detected
```

### Step 0.4: Install VirtualBox
1. Download and install VirtualBox + Extension Pack
2. Add to PATH:
```powershell
$env:Path += ";C:\Program Files\Oracle\VirtualBox"
[Environment]::SetEnvironmentVariable("Path", $env:Path, "User")
VBoxManage --version
```

### Step 0.5: Create Folder Structure
```powershell
mkdir D:\VMs
mkdir D:\VMs\shared
mkdir D:\VMs\iso
mkdir D:\VMs\media
VBoxManage setproperty machinefolder D:\VMs
```

### Step 0.6: Identify Network Adapter
```powershell
VBoxManage list bridgedifs | Select-String "^Name:", "^IPAddress:", "^Status:"
```
Pick wired Ethernet adapter that is `Up`. Set as variable:
```powershell
$BR = "Intel(R) Ethernet Connection (2) I219-V"   # Replace with your adapter
```

**Gate:** VBoxManage works, adapter visible, 400GB free space.

---

## Phase 1: Download Media

### Required Downloads

| Item | Source | Destination |
|------|--------|-------------|
| OracleLinux-R9-U8-x86_64-dvd.iso | Oracle Software Delivery Cloud | D:\VMs\iso\ |
| LINUX.X64_193000_grid_home.zip | Oracle Technology Network | D:\VMs\media\ |
| LINUX.X64_193000_db_home.zip | Oracle Technology Network | D:\VMs\media\ |
| Patch 37957391 (GI RU 19.28) | My Oracle Support | D:\VMs\media\ |
| Patch 38336965 | My Oracle Support | D:\VMs\media\ |
| Patch 34436514 | My Oracle Support | D:\VMs\media\ |
| Patch 6880880 (OPatch) | My Oracle Support | D:\VMs\media\ |

**Gate:** All files downloaded (~20GB total).

---

## Phase 2: Build Golden VM

**Goal:** Create template VM with Oracle Linux 9.8, UEK7 kernel, base packages.

### Step 2.1: Create VM
```powershell
VBoxManage createvm --name ol9-golden --ostype Oracle9_64 --register
VBoxManage modifyvm ol9-golden --memory 4096 --cpus 2 --firmware bios
VBoxManage modifyvm ol9-golden --nic1 bridged --bridgeadapter1 "$BR"
VBoxManage modifyvm ol9-golden --graphicscontroller vmsvga --vram 16
VBoxManage modifyvm ol9-golden --ioapic on --pae off --nested-hw-virt off

VBoxManage createmedium disk --filename D:\VMs\ol9-golden\ol9-golden.vdi --size 40960 --format VDI
VBoxManage storagectl ol9-golden --name "SATA" --add sata --controller IntelAhci --portcount 8 --hostiocache on
VBoxManage storageattach ol9-golden --storagectl "SATA" --port 0 --device 0 --type hdd --medium D:\VMs\ol9-golden\ol9-golden.vdi

VBoxManage storagectl ol9-golden --name "IDE" --add ide
VBoxManage storageattach ol9-golden --storagectl "IDE" --port 0 --device 0 --type dvddrive --medium D:\VMs\iso\OracleLinux-R9-U8-x86_64-dvd.iso

VBoxManage startvm ol9-golden
```

### Step 2.2: OS Installation Choices
| Screen | Choice |
|--------|--------|
| Software selection | Minimal Install (no GUI) |
| Installation destination | Custom partitioning |
| Partitioning | Standard Partition |
| /boot | 1 GB, xfs |
| / | All remaining space, xfs |
| swap | None (delete if proposed) |
| KDUMP | Disabled |
| Network | DHCP (for now) |
| Hostname | ol9-golden |
| SELinux | Enforcing |
| Root password | Set one |

### Step 2.3: First Boot - Pin UEK7 Kernel
```bash
uname -r    # If 6.12.x, pin UEK7:

dnf install -y dnf-utils
dnf config-manager --set-enabled ol9_UEKR7
dnf config-manager --set-disabled ol9_UEKR8
dnf install -y kernel-uek

grubby --info=ALL | grep -E "^kernel|^index"
grubby --set-default /boot/vmlinuz-$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-uek | grep ^5.15 | head -1)
reboot
```

### Step 2.4: Base Packages
```bash
dnf update -y
dnf install -y \
  chrony selinux-policy-devel policycoreutils-python-utils \
  nfs-utils lvm2 bind-utils net-tools bash-completion \
  vim tar unzip git wget curl
```

### Step 2.5: Disable Swap
```bash
swapoff -a
sed -i '/swap/d' /etc/fstab
free -m      # Swap must be 0 0 0
```

### Step 2.6: Kernel Parameters
```bash
cat >> /etc/sysctl.conf <<'EOF'
fs.file-max = 6815744
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
fs.aio-max-nr = 1048576
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

modprobe br_netfilter
echo br_netfilter > /etc/modules-load.d/br_netfilter.conf
sysctl -p
```

### Step 2.7: Clock Source and Time
```bash
echo "tsc" > /sys/devices/system/clocksource/clocksource0/current_clocksource

sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 numa=off transparent_hugepage=never clocksource=tsc"/' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg

systemctl enable --now chronyd
chronyc tracking
```

### Step 2.8: SSH Key Setup
```bash
ssh-keygen -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd
```

### Step 2.9: Clean Up and Shutdown
```bash
dnf clean all
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /etc/NetworkManager/system-connections/*
history -c
shutdown -h now
```

Detach ISO:
```powershell
VBoxManage storageattach ol9-golden --storagectl "IDE" --port 0 --device 0 --type dvddrive --medium none
```

**Gate:** uname -r shows 5.15.x, swap 0, clocksource tsc, SELinux enforcing.

**SNAPSHOT: `00-golden`**

---

## Phase 3: Clone and Configure VMs

### Step 3.1: Clone VMs
```powershell
VBoxManage clonevm ol9-golden --name ocne-op  --register --mode machine
VBoxManage clonevm ol9-golden --name ocne-cp1 --register --mode machine
VBoxManage clonevm ol9-golden --name ocne-w1  --register --mode machine
VBoxManage clonevm ol9-golden --name ocne-w2  --register --mode machine
```

### Step 3.2: Configure VM Resources
```powershell
$BR = "Intel(R) Ethernet Connection (2) I219-V"   # Your adapter

# Operator node
VBoxManage modifyvm ocne-op --memory 4096 --cpus 2
VBoxManage modifyvm ocne-op --nic1 bridged --bridgeadapter1 "$BR"

# Control plane
VBoxManage modifyvm ocne-cp1 --memory 6144 --cpus 4
VBoxManage modifyvm ocne-cp1 --nic1 bridged --bridgeadapter1 "$BR"

# Worker 1
VBoxManage modifyvm ocne-w1 --memory 20480 --cpus 8
VBoxManage modifyvm ocne-w1 --nic1 bridged --bridgeadapter1 "$BR"
VBoxManage modifyvm ocne-w1 --nic2 intnet --intnet2 racpriv1 --nicpromisc2 allow-all --nictype2 virtio
VBoxManage modifyvm ocne-w1 --nic3 intnet --intnet3 racpriv2 --nicpromisc3 allow-all --nictype3 virtio

# Worker 2
VBoxManage modifyvm ocne-w2 --memory 20480 --cpus 8
VBoxManage modifyvm ocne-w2 --nic1 bridged --bridgeadapter1 "$BR"
VBoxManage modifyvm ocne-w2 --nic2 intnet --intnet2 racpriv1 --nicpromisc2 allow-all --nictype2 virtio
VBoxManage modifyvm ocne-w2 --nic3 intnet --intnet3 racpriv2 --nicpromisc3 allow-all --nictype3 virtio
```

### Step 3.3: Configure Static IPs (on each VM)

Boot each VM and configure:

| VM | Hostname | IP |
|----|----------|-----|
| ocne-op | ocne-op.lab.local | 192.168.1.210 |
| ocne-cp1 | ocne-cp1.lab.local | 192.168.1.211 |
| ocne-w1 | ocne-w1.lab.local | 192.168.1.221 |
| ocne-w2 | ocne-w2.lab.local | 192.168.1.222 |

```bash
# Adjust HOST and IP for each VM
HOST=ocne-op.lab.local
IP=192.168.1.210
GW=192.168.1.1
DEV=enp0s3

hostnamectl set-hostname $HOST

CON=$(nmcli -t -g GENERAL.CONNECTION dev show $DEV | head -1)
nmcli con mod "$CON" \
  ipv4.method manual \
  ipv4.addresses $IP/24 \
  ipv4.gateway $GW \
  ipv4.dns "$GW 1.1.1.1" \
  connection.autoconnect yes
nmcli con down "$CON"; nmcli con up "$CON"

ip -br addr show $DEV
ping -c2 $GW
```

### Step 3.4: Configure Private Interfaces on Workers (no IP)
On both ocne-w1 and ocne-w2:
```bash
ip -br link    # Identify enp0s8 and enp0s9

nmcli con add type ethernet ifname enp0s8 con-name priv1 ipv4.method disabled ipv6.method disabled mtu 9000
nmcli con add type ethernet ifname enp0s9 con-name priv2 ipv4.method disabled ipv6.method disabled mtu 9000
nmcli con up priv1
nmcli con up priv2
```

### Step 3.5: /etc/hosts on All 4 VMs
```bash
cat >> /etc/hosts <<'EOF'
192.168.1.210  ocne-op.lab.local   ocne-op
192.168.1.211  ocne-cp1.lab.local  ocne-cp1
192.168.1.221  ocne-w1.lab.local   ocne-w1
192.168.1.222  ocne-w2.lab.local   ocne-w2
EOF
```

Also add to Windows: `C:\Windows\System32\drivers\etc\hosts`

### Step 3.6: Verify SSH from ocne-op
```bash
for h in ocne-op ocne-cp1 ocne-w1 ocne-w2; do
  echo "--- $h"
  ssh -o StrictHostKeyChecking=no root@$h hostname
done
```

**Gate:** All 4 VMs pingable, passwordless SSH from ocne-op to all.

---

## Phase 4: Storage Setup

**Power off all VMs first.**

### Step 4.1: Worker Data Disks
```powershell
VBoxManage createmedium disk --filename D:\VMs\ocne-w1\ocne-w1-data.vdi --size 112640 --format VDI
VBoxManage storageattach ocne-w1 --storagectl "SATA" --port 1 --device 0 --type hdd --medium D:\VMs\ocne-w1\ocne-w1-data.vdi

VBoxManage createmedium disk --filename D:\VMs\ocne-w2\ocne-w2-data.vdi --size 112640 --format VDI
VBoxManage storageattach ocne-w2 --storagectl "SATA" --port 1 --device 0 --type hdd --medium D:\VMs\ocne-w2\ocne-w2-data.vdi
```

### Step 4.2: NFS Disk on Operator
```powershell
VBoxManage createmedium disk --filename D:\VMs\ocne-op\ocne-op-nfs.vdi --size 153600 --format VDI
VBoxManage storageattach ocne-op --storagectl "SATA" --port 1 --device 0 --type hdd --medium D:\VMs\ocne-op\ocne-op-nfs.vdi
```

### Step 4.3: Shared ASM Disks (Fixed Size, Shareable)
```powershell
VBoxManage createmedium disk --filename D:\VMs\shared\asm1.vdi --size 40960 --format VDI --variant Fixed
VBoxManage createmedium disk --filename D:\VMs\shared\asm2.vdi --size 40960 --format VDI --variant Fixed
VBoxManage createmedium disk --filename D:\VMs\shared\asm3.vdi --size 20480 --format VDI --variant Fixed

VBoxManage modifymedium disk D:\VMs\shared\asm1.vdi --type shareable
VBoxManage modifymedium disk D:\VMs\shared\asm2.vdi --type shareable
VBoxManage modifymedium disk D:\VMs\shared\asm3.vdi --type shareable
```

### Step 4.4: Attach ASM Disks to Both Workers
```powershell
foreach ($vm in @("ocne-w1","ocne-w2")) {
  VBoxManage storageattach $vm --storagectl "SATA" --port 2 --device 0 --type hdd --medium D:\VMs\shared\asm1.vdi --mtype shareable
  VBoxManage storageattach $vm --storagectl "SATA" --port 3 --device 0 --type hdd --medium D:\VMs\shared\asm2.vdi --mtype shareable
  VBoxManage storageattach $vm --storagectl "SATA" --port 4 --device 0 --type hdd --medium D:\VMs\shared\asm3.vdi --mtype shareable
}
```

### Step 4.5: Set Serial Numbers for Stable Device Names
```powershell
foreach ($vm in @("ocne-w1","ocne-w2")) {
  VBoxManage setextradata $vm "VBoxInternal/Devices/ahci/0/Config/Port2/SerialNumber" "asmdisk0001"
  VBoxManage setextradata $vm "VBoxInternal/Devices/ahci/0/Config/Port3/SerialNumber" "asmdisk0002"
  VBoxManage setextradata $vm "VBoxInternal/Devices/ahci/0/Config/Port4/SerialNumber" "asmdisk0003"
}
```

### Step 4.6: Worker Data Disk Layout (on both workers)
Boot workers, then:
```bash
pvcreate /dev/sdb
vgcreate vg_data /dev/sdb
lvcreate -L 60G -n lv_containers vg_data
lvcreate -l 100%FREE -n lv_scratch vg_data

mkfs.xfs /dev/vg_data/lv_containers
mkfs.xfs /dev/vg_data/lv_scratch

mkdir -p /var/lib/containers /scratch

cat >> /etc/fstab <<'EOF'
/dev/vg_data/lv_containers  /var/lib/containers  xfs  defaults  0 0
/dev/vg_data/lv_scratch     /scratch             xfs  defaults  0 0
EOF

mount -a
df -h /var/lib/containers /scratch
```

### Step 4.7: NFS Server on ocne-op
```bash
pvcreate /dev/sdb
vgcreate vg_nfs /dev/sdb
lvcreate -l 100%FREE -n lv_export vg_nfs
mkfs.xfs /dev/vg_nfs/lv_export

mkdir -p /export
echo '/dev/vg_nfs/lv_export  /export  xfs  defaults  0 0' >> /etc/fstab
mount -a

mkdir -p /export/stage /export/oradata

groupadd -g 54321 oinstall 2>/dev/null
useradd -u 54321 -g 54321 oracle 2>/dev/null
chown -R 54321:54321 /export
chmod -R 775 /export

cat > /etc/exports <<'EOF'
/export/stage    192.168.1.0/24(rw,sync,no_root_squash,no_subtree_check)
/export/oradata  192.168.1.0/24(rw,sync,no_root_squash,no_subtree_check)
EOF

systemctl enable --now nfs-server
exportfs -rav

firewall-cmd --permanent --add-service=nfs
firewall-cmd --permanent --add-service=rpc-bind
firewall-cmd --permanent --add-service=mountd
firewall-cmd --reload
```

### Step 4.8: Mount NFS Stage on Workers
On both workers:
```bash
setsebool -P virt_use_nfs on
mkdir -p /scratch/software/stage

echo 'ocne-op:/export/stage  /scratch/software/stage  nfs  rw,bg,hard,nointr,rsize=32768,wsize=32768,tcp,vers=3,timeo=600,actimeo=0  0 0' >> /etc/fstab
mount -a
df -h /scratch/software/stage
```

### Step 4.9: Stage Media
Copy zips from Windows to `ocne-op:/export/stage`, then:
```bash
cd /export/stage
chmod 755 *.zip
chown 54321:54321 *.zip
ls -la
```

**Gate:** lsblk shows 5 devices on workers, /var/lib/containers and /scratch mounted, NFS visible on workers.

---

## Phase 5: Install OCNE 1.9

### Step 5.1: Enable OCNE Repository (all 4 nodes)
```bash
dnf install -y oracle-olcne-release-el9
dnf config-manager --set-enabled ol9_olcne19 ol9_addons ol9_baseos_latest ol9_appstream ol9_UEKR7
dnf config-manager --set-disabled ol9_olcne18 ol9_olcne17
```

### Step 5.2: Install Platform Packages

On **ocne-op**:
```bash
dnf install -y olcnectl olcne-api-server olcne-utils
systemctl enable olcne-api-server.service
```

On **ocne-cp1, ocne-w1, ocne-w2**:
```bash
dnf install -y olcne-agent olcne-utils
systemctl enable olcne-agent.service
```

### Step 5.3: Firewall Rules

On **ocne-cp1**:
```bash
firewall-cmd --add-port=8090/tcp --permanent
firewall-cmd --add-port=10250/tcp --permanent
firewall-cmd --add-port=10255/tcp --permanent
firewall-cmd --add-port=8472/udp --permanent
firewall-cmd --add-port=6443/tcp --permanent
firewall-cmd --add-port=2379-2380/tcp --permanent
firewall-cmd --add-port=10251-10252/tcp --permanent
firewall-cmd --add-masquerade --permanent
firewall-cmd --reload
```

On **both workers**:
```bash
firewall-cmd --add-port=8090/tcp --permanent
firewall-cmd --add-port=10250/tcp --permanent
firewall-cmd --add-port=10255/tcp --permanent
firewall-cmd --add-port=8472/udp --permanent
firewall-cmd --add-masquerade --permanent
firewall-cmd --reload
```

### Step 5.4: Provision Cluster (from ocne-op)
```bash
olcnectl provision \
  --api-server ocne-op.lab.local \
  --control-plane-nodes ocne-cp1.lab.local \
  --worker-nodes ocne-w1.lab.local,ocne-w2.lab.local \
  --environment-name ocnelab \
  --name ocnecluster \
  --selinux enforcing \
  --yes
```
**This takes 10-20 minutes.**

### Step 5.5: Setup kubectl

On **ocne-cp1**:
```bash
mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc

kubectl get nodes -o wide
```

Copy to ocne-op:
```bash
# on ocne-op
mkdir -p $HOME/.kube
scp root@ocne-cp1:/etc/kubernetes/admin.conf $HOME/.kube/config
```

### Step 5.6: Label Workers
```bash
kubectl label node ocne-w1.lab.local node-role.kubernetes.io/worker=
kubectl label node ocne-w2.lab.local node-role.kubernetes.io/worker=
kubectl label node ocne-w1.lab.local raccluster=raccluster01
kubectl label node ocne-w2.lab.local raccluster=raccluster01
```

**Gate:** 3 nodes Ready, all kube-system pods Running.

**SNAPSHOT: `01-ocne-base`**

---

## Phase 6: Install Operator, Multus, cert-manager

### Step 6.1: Add Multus Module (from ocne-op)
```bash
olcnectl module create \
  --environment-name ocnelab \
  --module multus \
  --name mymultus \
  --multus-kubernetes-module ocnecluster

olcnectl module install --environment-name ocnelab --name mymultus
```

### Step 6.2: Install cert-manager
Check `cert-manager.io/docs/releases/` for version supporting K8s 1.29.
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
kubectl get pods -n cert-manager -w    # Wait for all 3 pods Running
```

### Step 6.3: Clone Operator Repository
```bash
cd /root
git clone https://github.com/oracle/oracle-database-operator.git
cd oracle-database-operator
```

### Step 6.4: Create Namespaces
```bash
kubectl create ns rac
kubectl create ns sidb
```

### Step 6.5: Install Operator (Namespace-Scoped)
```bash
scripts/generate-namespace-install.sh oracle-database-operator-system,sidb,rac

kubectl apply -f dist/install/oracle-database-operator-rbac.yaml
kubectl apply -f dist/install/oracle-database-operator-system.yaml
```

### Step 6.6: Apply Cluster-Scoped RBAC
```bash
kubectl apply -f rbac/node-rbac.yaml
kubectl apply -f rbac/storage-class-rbac.yaml
kubectl apply -f rbac/persistent-volume-rbac.yaml
kubectl apply -f docs/rac/rbac/pv-rbac.yaml
kubectl apply -f rbac/multus-rbac.yaml
```

### Step 6.7: Create Image Pull Secret
```bash
for ns in sidb rac; do
  kubectl create secret docker-registry oracle-container-registry-secret \
    --docker-server=container-registry.oracle.com \
    --docker-username='<your-oracle-sso-email>' \
    --docker-password='<your-oracle-sso-password>' \
    -n "$ns"
done
```

### Step 6.8: Verify
```bash
kubectl get pods -n oracle-database-operator-system
kubectl get crd | grep database.oracle.com
```

**Gate:** 3 controller-manager pods Running, CRDs present.

**SNAPSHOT: `02-operator-installed`**

---

## Phase A: SIDB + Data Guard

**See:** `phase-a-sidb-dataguard-setup.md` for complete walkthrough.

### Quick Summary

1. Install local-path-provisioner StorageClass
2. Create NFS PV/PVC for database storage
3. Deploy primary SingleInstanceDatabase
4. Wait for database to be ready (30-60 min)
5. Create Data Guard prerequisites script
6. Deploy standby SingleInstanceDatabase
7. Create DataguardBroker CR
8. Test switchover operations

### Key Commands
```bash
# Check primary database status
kubectl get singleinstancedatabase -n sidb

# Check Data Guard broker status
kubectl get dataguardbroker -n sidb

# View database logs
kubectl logs -n sidb <pod-name> -c oracle-db
```

---

## Phase B: Oracle Restart + ASM

**See:** `phase-b-oracle-restart-asm-setup.md` for complete walkthrough.

### Quick Summary

1. Fix RBAC for StorageClass/PV permissions
2. Configure HugePages (2GB, not 6GB - memory constraints)
3. Add allowed-unsafe-sysctls to kubelet
4. Deploy OracleRestart CR
5. Handle glibc 2.34+ compatibility (libstat_compat.a)
6. Install Grid Infrastructure with -applyRU
7. Install Database software with -applyRU
8. Create ASM disk group manually (if needed)
9. Create database manually with SQL*Plus (if DBCA fails)
10. Register database with Oracle Restart

### Key Commands
```bash
# Check Oracle Restart status
kubectl get oraclerestart -n rac

# Inside pod - check Oracle Restart
crsctl stat res -t

# Check ASM
asmcmd lsdg

# Check database
srvctl status database -d ORCL
```

---

## Troubleshooting Quick Reference

| Issue | Solution |
|-------|----------|
| VMs slow, nodes evicted | Disable Hyper-V + Memory Integrity |
| Network adapter not found | Check USB port, update $BR |
| SSH fails from ocne-op | Check authorized_keys, PermitRootLogin |
| kubelet won't start | swapoff -a, check /etc/fstab |
| cert-manager CrashLoop | Use version compatible with K8s 1.29 |
| Image pull fails | Accept license at container-registry.oracle.com |
| PVC stuck Pending | Install StorageClass first |
| ORA-27054 on NFS | Use exact mount options from Phase 4.8 |
| Permission denied in pod | Check ownership 54321:54321, no_root_squash |
| glibc 2.34 error | Create libstat_compat.a workaround |
| DBCA CVU fails | Create database manually with SQL*Plus |

---

## File References

| File | Purpose |
|------|---------|
| runbook.md | Main runbook with Phases 0-6 details |
| phase-a-sidb-dataguard-setup.md | Phase A complete walkthrough |
| phase-b-oracle-restart-asm-setup.md | Phase B complete walkthrough |
| architecture-diagrams.md | Infrastructure and architecture diagrams |
| lab.env | Environment variables (IPs, hostnames, paths) |
| CLAUDE.md | Instructions for AI assistant |

---

## Snapshot Summary

| Snapshot | After Phase | Restore Point |
|----------|-------------|---------------|
| 00-golden | Phase 2 | Rebuild any VM |
| 01-ocne-base | Phase 5 | Before operator experiments |
| 02-operator-installed | Phase 6 | Before database deployment |
| 03-phase-a-done | Phase A | Before ASM work |
| 04-rac-prereqs | Phase B1 | Before RAC provision |

---

## Cleanup: Reset Phase A (SIDB + Data Guard)

Use these steps to remove Phase A resources and start fresh. Run from a node with kubectl access.

### Step 1: Delete Data Guard Broker (if exists)
```bash
kubectl get dataguardbroker -n sidb
kubectl delete dataguardbroker --all -n sidb

# Wait for deletion
kubectl get pods -n sidb -w
```

### Step 2: Delete Standby Database
```bash
kubectl get singleinstancedatabase -n sidb

# Delete standby first (if using Data Guard)
kubectl delete singleinstancedatabase sidb-standby -n sidb

# Wait for pod termination
kubectl get pods -n sidb -w
```

### Step 3: Delete Primary Database
```bash
kubectl delete singleinstancedatabase sidb-primary -n sidb

# Wait for all pods gone
kubectl get pods -n sidb -w
```

### Step 4: Delete PVCs
```bash
kubectl get pvc -n sidb
kubectl delete pvc --all -n sidb
```

### Step 5: Delete PVs
```bash
# List PVs related to sidb
kubectl get pv | grep sidb

# Delete them (adjust names as needed)
kubectl delete pv sidb-pv-primary sidb-pv-standby

# Or delete all Released PVs
kubectl get pv | grep Released | awk '{print $1}' | xargs kubectl delete pv
```

### Step 6: Clean NFS Data Directories (on ocne-op)
```bash
# SSH to ocne-op
ssh root@ocne-op

# Remove database files (DESTRUCTIVE!)
rm -rf /export/oradata/*

# Recreate empty directories with correct ownership
mkdir -p /export/oradata
chown -R 54321:54321 /export/oradata
chmod -R 775 /export/oradata

# Verify
ls -la /export/oradata
```

### Step 7: Verify Cleanup
```bash
kubectl get all -n sidb
kubectl get pvc -n sidb
kubectl get pv | grep sidb
```

### Optional: Keep or Recreate Secrets
```bash
# Check existing secrets
kubectl get secrets -n sidb

# If you need to recreate the image pull secret:
kubectl delete secret oracle-container-registry-secret -n sidb

kubectl create secret docker-registry oracle-container-registry-secret \
  --docker-server=container-registry.oracle.com \
  --docker-username='<your-oracle-sso-email>' \
  --docker-password='<your-oracle-sso-password>' \
  -n sidb
```

**Phase A is now reset. You can re-run phase-a-sidb-dataguard-setup.md from the beginning.**

---

## Cleanup: Reset Phase B (Oracle Restart + ASM)

Use these steps to remove Phase B resources and start fresh.

### Step 1: Delete OracleRestart CR
```bash
kubectl get oraclerestart -n rac

# Delete the OracleRestart resource
kubectl delete oraclerestart --all -n rac

# Watch pods terminate (may take several minutes)
kubectl get pods -n rac -w
```

### Step 2: Force Delete Stuck Pods (if needed)
If pods are stuck in Terminating:
```bash
# List stuck pods
kubectl get pods -n rac

# Force delete (use with caution)
kubectl delete pod <pod-name> -n rac --force --grace-period=0
```

### Step 3: Delete PVCs
```bash
kubectl get pvc -n rac
kubectl delete pvc --all -n rac
```

### Step 4: Delete PVs
```bash
# List PVs related to rac/oracle-restart
kubectl get pv | grep -E "rac|asm|oracle"

# Delete them
kubectl delete pv <pv-names>

# Or delete all Released PVs
kubectl get pv | grep Released | awk '{print $1}' | xargs kubectl delete pv
```

### Step 5: Clean Worker Node Directories (on both workers)

On **ocne-w1** and **ocne-w2**:
```bash
# Remove Oracle installation directories (DESTRUCTIVE!)
rm -rf /scratch/oracle/*
rm -rf /scratch/oraInventory/*

# Recreate with correct ownership
mkdir -p /scratch/oracle/app/oracle
mkdir -p /scratch/oracle/app/grid
mkdir -p /scratch/oraInventory

chown -R 54321:54321 /scratch/oracle
chown -R 54321:54321 /scratch/oraInventory
chmod -R 775 /scratch/oracle
chmod -R 775 /scratch/oraInventory

# Verify
ls -la /scratch/
```

### Step 6: Wipe ASM Disk Headers (on both workers)

**CRITICAL: This destroys all data on ASM disks!**

On **ocne-w1** and **ocne-w2**:
```bash
# Verify which disks are ASM disks
lsblk
ls -l /dev/disk/by-id/ | grep asmdisk

# Wipe first 100MB of each ASM disk (clears headers)
dd if=/dev/zero of=/dev/sdc bs=1M count=100
dd if=/dev/zero of=/dev/sdd bs=1M count=100
dd if=/dev/zero of=/dev/sde bs=1M count=100

# Verify disks are clean (should show no partition table)
fdisk -l /dev/sdc /dev/sdd /dev/sde
```

### Step 7: Remove udev Rules (if any were created)
On both workers:
```bash
rm -f /etc/udev/rules.d/99-oracle-asmdevices.rules
udevadm control --reload-rules
udevadm trigger
```

### Step 8: Verify Cleanup
```bash
kubectl get all -n rac
kubectl get pvc -n rac
kubectl get pv | grep -E "rac|asm|oracle"

# On workers
ls -la /scratch/oracle/
ls -la /scratch/oraInventory/
lsblk
```

### Optional: Keep or Recreate Secrets
```bash
# Check existing secrets
kubectl get secrets -n rac

# If you need to recreate:
kubectl delete secret oracle-container-registry-secret -n rac

kubectl create secret docker-registry oracle-container-registry-secret \
  --docker-server=container-registry.oracle.com \
  --docker-username='<your-oracle-sso-email>' \
  --docker-password='<your-oracle-sso-password>' \
  -n rac
```

**Phase B is now reset. You can re-run phase-b-oracle-restart-asm-setup.md from the beginning.**

---

## Cleanup: Full Reset to Snapshot

If cleanup steps fail or you want a guaranteed clean slate:

### Option 1: Restore from VirtualBox Snapshot
```powershell
# Power off all VMs first
foreach ($vm in @("ocne-op","ocne-cp1","ocne-w1","ocne-w2")) {
    VBoxManage controlvm $vm poweroff 2>$null
}

# Wait a few seconds
Start-Sleep -Seconds 5

# Restore to snapshot (e.g., 02-operator-installed)
foreach ($vm in @("ocne-op","ocne-cp1","ocne-w1","ocne-w2")) {
    VBoxManage snapshot $vm restore "02-operator-installed"
}

# Start VMs
foreach ($vm in @("ocne-op","ocne-cp1","ocne-w1","ocne-w2")) {
    VBoxManage startvm $vm --type headless
}
```

### Option 2: Reset Kubernetes Namespaces Only
```bash
# Delete and recreate namespaces (removes ALL resources in them)
kubectl delete ns sidb
kubectl delete ns rac

kubectl create ns sidb
kubectl create ns rac

# Recreate image pull secrets
for ns in sidb rac; do
  kubectl create secret docker-registry oracle-container-registry-secret \
    --docker-server=container-registry.oracle.com \
    --docker-username='<your-oracle-sso-email>' \
    --docker-password='<your-oracle-sso-password>' \
    -n "$ns"
done
```

**Note:** Namespace deletion removes Kubernetes resources but does NOT clean:
- NFS data on ocne-op
- Local files on worker nodes
- ASM disk headers

You must still run the storage cleanup steps above.

---

## Quick Reset Commands Summary

### Reset Phase A Only
```bash
# From kubectl node
kubectl delete dataguardbroker --all -n sidb
kubectl delete singleinstancedatabase --all -n sidb
kubectl delete pvc --all -n sidb
kubectl get pv | grep sidb | awk '{print $1}' | xargs kubectl delete pv

# On ocne-op
ssh root@ocne-op "rm -rf /export/oradata/* && chown -R 54321:54321 /export/oradata"
```

### Reset Phase B Only
```bash
# From kubectl node
kubectl delete oraclerestart --all -n rac
kubectl delete pvc --all -n rac
kubectl get pv | grep -E 'rac|asm' | awk '{print $1}' | xargs kubectl delete pv

# On both workers (run on each)
for host in ocne-w1 ocne-w2; do
  ssh root@$host 'rm -rf /scratch/oracle/* /scratch/oraInventory/* && \
    mkdir -p /scratch/oracle/app/oracle /scratch/oracle/app/grid /scratch/oraInventory && \
    chown -R 54321:54321 /scratch/oracle /scratch/oraInventory && \
    dd if=/dev/zero of=/dev/sdc bs=1M count=100 && \
    dd if=/dev/zero of=/dev/sdd bs=1M count=100 && \
    dd if=/dev/zero of=/dev/sde bs=1M count=100'
done
```

### Reset Both Phases
```bash
# Namespaces
kubectl delete ns sidb rac
kubectl create ns sidb
kubectl create ns rac

# Recreate secrets
for ns in sidb rac; do
  kubectl create secret docker-registry oracle-container-registry-secret \
    --docker-server=container-registry.oracle.com \
    --docker-username='<your-email>' \
    --docker-password='<your-password>' \
    -n "$ns"
done

# NFS cleanup (ocne-op)
ssh root@ocne-op 'rm -rf /export/oradata/* && chown -R 54321:54321 /export/oradata'

# Worker cleanup (both)
for host in ocne-w1 ocne-w2; do
  ssh root@$host 'rm -rf /scratch/oracle/* /scratch/oraInventory/* && \
    mkdir -p /scratch/oracle/app/oracle /scratch/oracle/app/grid /scratch/oraInventory && \
    chown -R 54321:54321 /scratch/oracle /scratch/oraInventory && \
    dd if=/dev/zero of=/dev/sdc bs=1M count=100 && \
    dd if=/dev/zero of=/dev/sdd bs=1M count=100 && \
    dd if=/dev/zero of=/dev/sde bs=1M count=100'
done
```
