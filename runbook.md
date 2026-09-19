# OCNE 1.9 Home Lab Runbook — Phases 0-6

Build a 4-VM Oracle Cloud Native Environment 1.9 cluster on VirtualBox, with the Oracle
Database Operator installed and verified. Stops before any database is deployed. Phase A
(SingleInstanceDatabase + Data Guard), phase B (Oracle Restart + ASM) and phase C (RAC)
follow separately.

---

## Scope and target architecture

**Host:** Windows, 64 GB RAM, 26 logical processors, 500 GB to 1 TB free disk, Oracle VirtualBox.

### VM inventory

| VM | Role | vCPU | RAM | Disks | NICs |
|---|---|---|---|---|---|
| `ocne-op` | olcnectl operator + NFS media server | 2 | 4 GB | 40 GB OS + 150 GB NFS | 1 |
| `ocne-cp1` | Kubernetes control plane | 4 | 6 GB | 60 GB OS | 1 |
| `ocne-w1` | worker / future racnode1 | 8 | 20 GB | 40 GB OS + 110 GB data | 3 |
| `ocne-w2` | worker / future racnode2 | 8 | 20 GB | 40 GB OS + 110 GB data | 3 |

Total allocated RAM 50 GB, leaving about 14 GB for Windows.

### Shared ASM disks

Three fixed-size VDIs, marked shareable, attached to **ocne-w1 and ocne-w2 only**. Never to
ocne-op or ocne-cp1.

| File | Size | Guest device | Purpose |
|---|---|---|---|
| `asm1.vdi` | 40 GB | /dev/sdc | DATA disk group member |
| `asm2.vdi` | 40 GB | /dev/sdd | DATA disk group member |
| `asm3.vdi` | 20 GB | /dev/sde | reserve, for the add/delete ASM disk exercise in phase C |

100 GB of real disk is consumed the moment these are created, because VirtualBox only allows
shareable on preallocated images.

### Storage rules

Three tiers that never mix:

1. **Private per-VM disks** (thin). OS, and the worker data disk carrying `/var/lib/containers`.
2. **Shared raw block devices** (fixed, shareable). ASM only. VirtualBox provides no locking
   on these; ASM and Clusterware do the arbitration. Putting a filesystem on one and mounting
   it on both workers corrupts it.
3. **NFS export from ocne-op**. Installation media, and later phase A datafiles. File-level,
   server-arbitrated, safe to share.

### Network map

| Network | VirtualBox type | Subnet | Used by |
|---|---|---|---|
| public | **Bridged** to the host's USB gigabit NIC | your home LAN | all 4 VMs: Kubernetes node network, Flannel, future RAC public, and access from any device at home |
| `racpriv1` | Internal Network | no IP | workers only, Multus macvlan, RAC interconnect 1 |
| `racpriv2` | Internal Network | no IP | workers only, Multus macvlan, RAC interconnect 2 |

Bridged means each VM takes an address on your home LAN, so the cluster is reachable from
your laptop, phone or any other machine in the house. It also removes the need for a NAT
adapter, since the bridge already provides outbound internet. Every VM therefore has **one**
public NIC, and the workers have two extra address-less ones.

This runbook uses `192.168.1.0/24` with gateway `192.168.1.1` as the worked example.
Substitute your own subnet everywhere it appears.

| Host | example IP |
|---|---|
| ocne-op | 192.168.1.210 |
| ocne-cp1 | 192.168.1.211 |
| ocne-w1 | 192.168.1.221 |
| ocne-w2 | 192.168.1.222 |

These four addresses must be **static and outside your router's DHCP pool**, or reserved by
MAC on the router. A node whose IP changes after a lease expiry breaks both Kubernetes and,
later, Clusterware.

**The host bridges onto a USB gigabit Ethernet adapter, not Wi-Fi.** VirtualBox cannot do
true MAC-level bridging over a wireless adapter; it rewrites source MACs and proxies ARP
instead, which carries plain IPv4 but introduces jitter and unreliable broadcast handling.
Since all node-to-node traffic (etcd, API server, kubelet, Flannel VXLAN) crosses the public
network, and both etcd and Clusterware respond to jitter with evictions and leader elections,
a wired path is worth the $20. Leave the host's Wi-Fi enabled for Windows itself if you like;
just bridge the VMs onto the USB adapter.

---

## Phase 0 — Windows host preparation

Do this first. If Hyper-V is active, VirtualBox runs on the Hyper-V backend at a fraction of
native speed, and Clusterware will evict nodes on timing alone. Every command below runs in
an **Administrator PowerShell**.

### 0.1 Check whether a hypervisor is already running

```powershell
systeminfo | Select-String "Hyper-V", "Virtualization"
```

If it says a hypervisor has been detected, continue. If it lists the virtualization
requirements as met and no hypervisor detected, skip to 0.4.

### 0.2 Turn off the Hyper-V stack

```powershell
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart

bcdedit /set hypervisorlaunchtype off
```

This disables Hyper-V, WSL2, Windows Sandbox and the platform shims Docker Desktop uses. If
you need Docker Desktop on this machine, you will be toggling it back and forth; plan on this
box being a lab box.

### 0.3 Turn off Memory Integrity

Settings → Privacy & security → Windows Security → Device security → Core isolation →
**Memory integrity: Off**.

This one is not scriptable reliably and is the most commonly missed step. It silently forces
Hyper-V-backed virtualisation even after 0.2.

**Reboot now.** Then confirm:

```powershell
systeminfo | Select-String "Hyper-V"
```

You want the four virtualization requirements listed as `Yes`, and no line saying a
hypervisor was detected.

### 0.4 Install VirtualBox and set PATH

Install the current VirtualBox plus the matching Extension Pack. Then, so the `VBoxManage`
commands in this runbook work from any prompt:

```powershell
$env:Path += ";C:\Program Files\Oracle\VirtualBox"
[Environment]::SetEnvironmentVariable("Path", $env:Path, "User")
VBoxManage --version
```

### 0.5 Create the folder layout

Adjust the drive letter to wherever your free space is. Everything in this runbook assumes
`D:\VMs`.

```powershell
mkdir D:\VMs
mkdir D:\VMs\shared
mkdir D:\VMs\iso
mkdir D:\VMs\media
VBoxManage setproperty machinefolder D:\VMs
```

### 0.6 Identify the bridged adapter and reserve addresses

Find the exact adapter name VirtualBox will bridge onto:

```powershell
VBoxManage list bridgedifs | Select-String "^Name:", "^IPAddress:", "^Status:"
```

Pick the **wired Ethernet** adapter that is `Up` and has your LAN address. Copy its `Name:`
string verbatim, including any bracketed text; you will paste it into every
`--bridgeadapter1` argument. Set it once as a variable for this session:

```powershell
$BR = "Intel(R) Ethernet Connection (2) I219-V"   # replace with your adapter name
```

**USB adapter specifics.** Three things about USB NICs that will cost you an evening otherwise:

- Plug it into the **same physical port** every time. Windows can enumerate the adapter as a
  new instance on a different port, which changes the name in `VBoxManage list bridgedifs`
  and leaves `--bridgeadapter1` pointing at something that no longer exists. The VMs then
  refuse to start, or start with a dead link.
- **Disable power management on it.** Device Manager → the adapter → Properties → Power
  Management → clear *Allow the computer to turn off this device to save power*. Also set USB
  selective suspend to Disabled under the active power plan. A NIC that sleeps mid-provision
  looks exactly like a cluster fault.
- **Install the vendor driver** (Realtek or ASIX, usually) rather than relying on the generic
  Windows one, and confirm the link negotiates at 1 Gbps before you build anything.

If both the USB adapter and Wi-Fi are up at once, make sure `$BR` names the USB adapter and
that Windows does not route your LAN subnet over Wi-Fi instead. `route print` shows which
interface owns the subnet; adjust the interface metric if it picked the wrong one.

Then find your subnet and gateway:

```powershell
ipconfig | Select-String "IPv4", "Default Gateway"
```

Finally, check your router's DHCP pool (usually something like .100 to .199) and pick four
addresses outside it. The runbook uses .210, .211, .221 and .222. If your router cannot be
configured to shrink its pool, use DHCP reservations by MAC instead, which VirtualBox makes
easy since each VM's MAC is fixed once created.

No host-only network is needed.

### 0.7 Confirm free space

You need roughly 400 GB free at peak. 100 GB of that is consumed immediately by the fixed ASM
disks in phase 4.

```powershell
Get-PSDrive D | Select-Object Used, Free
```

**Gate:** no hypervisor detected, `VBoxManage --version` works, USB adapter visible in
`bridgedifs` and `Up`, 400 GB free.

---

## Phase 1 — Media and downloads

Start these downloading now; they are slow and phase 5 onward blocks on them. Everything
lands in `D:\VMs\iso` or `D:\VMs\media`.

### 1.1 Operating system

Use the **full DVD ISO**, not the boot ISO. The boot ISO pulls every package from Oracle's
yum server during installation, which you would pay for once per VM.

- `OracleLinux-R9-U8-x86_64-dvd.iso` from Oracle Software Delivery Cloud or
  `yum.oracle.com/oracle-linux-isos.html`
- Put it in `D:\VMs\iso`

### 1.2 Oracle software, from Oracle Technology Network (free)

| Item | File |
|---|---|
| Grid Infrastructure 19.3.0 base | `LINUX.X64_193000_grid_home.zip` |
| Database 19.3.0 base | `LINUX.X64_193000_db_home.zip` |

### 1.3 Patches, from My Oracle Support (needs your CSI)

The RAC prerequisites require Grid Infrastructure and Database release **19.28 or later**, so
the base 19.3.0 alone does not qualify. You need these:

| Patch | What it is |
|---|---|
| 37957391 | GI Release Update 19.28.0 |
| 38336965 | recommended patch |
| 34436514 | recommended patch |
| 6880880 | OPatch, latest for 19.x |

Download the Linux x86-64 variants. Total is roughly 20 GB across all of section 1.2 and 1.3.

### 1.4 Container images

You do not download these to Windows; the worker nodes pull them. But you must **accept the
licence now**, or the pull fails later with an authorization error that looks like a
credentials bug.

1. Sign in at `container-registry.oracle.com`.
2. Navigate to **Database** and accept the terms for `database/enterprise` (needed for phase A
   Data Guard) and for the RAC slim image.
3. Note the images you will reference later:
   - `container-registry.oracle.com/database/enterprise:19.3.0.0` — phase A
   - `dbocir/oracle/database-rac:19.3.0-slim` — phase C

### 1.5 Optional but worth it later: a Gold Image

The RAC prerequisites suggest building a Gold Image containing the base software plus the RU
plus the recommended patches, so provisioning does not spend hours patching inside the pod.
See Doc ID 2965269.1 and 2915366.2 on My Oracle Support.

Do **not** block your first build on this. Get a working RAC with the plain zips first, then
rebuild a Gold Image once you know the shape of the thing. It cuts an hour or more off every
subsequent provision.

**Gate:** DVD ISO present, both 19.3.0 zips present, the four patch zips present, container
registry licences accepted.

---

## Phase 2 — Build the golden VM

One template, built once, cloned four times. Keep it minimal: **one 40 GB disk, one bridged
adapter**. Extra disks and NICs get added per clone in phase 3. Everything you do here, all
four nodes inherit, so a mistake here is a mistake four times.

### 2.1 Create the VM

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

The golden VM boots straight onto your LAN via DHCP, which is what you want during the build:
`dnf` works immediately. Static addressing happens per clone in phase 3.

### 2.2 Installer choices

| Screen | Choice |
|---|---|
| Software selection | **Minimal Install**. No GUI. |
| Installation destination | **Custom** partitioning, not automatic |
| Partitioning scheme | Standard Partition (simpler than LVM for a 40 GB root) |
| `/boot` | 1 GB, xfs |
| `/` | **all remaining space**, xfs |
| swap | **none**. Delete the swap partition if the installer proposes one. |
| KDUMP | disabled |
| Network | leave DHCP for now |
| Hostname | `ol9-golden` |
| SELinux | leave enforcing |
| Root password | set one; also create a user if you like |

Automatic partitioning will hand you a 15 GB root with the rest idle in a volume group. That
is the trap this table exists to avoid.

### 2.3 First boot: check and pin the kernel

Oracle Linux 9.8 will very likely boot UEK Release 8 (kernel 6.12.x). The RAC prerequisites
target UEK Release 7 (5.15.x), which is what the RAC slim image, the SELinux policy module
and OCNE 1.9 were tested against.

```bash
uname -r
```

If that shows `6.12.x`, pin UEK7:

```bash
dnf install -y dnf-utils
dnf config-manager --set-enabled ol9_UEKR7
dnf config-manager --set-disabled ol9_UEKR8
dnf install -y kernel-uek

# find the 5.15 kernel and make it default
grubby --info=ALL | grep -E "^kernel|^index"
grubby --set-default /boot/vmlinuz-$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-uek | grep ^5.15 | head -1)
reboot
```

After the reboot, `uname -r` must report 5.15.x. Do not proceed otherwise; mixed or untested
kernels across workers is a bad place to debug Clusterware from.

### 2.4 Base packages

```bash
dnf update -y
dnf install -y \
  chrony \
  selinux-policy-devel \
  policycoreutils-python-utils \
  nfs-utils \
  lvm2 \
  bind-utils \
  net-tools \
  bash-completion \
  vim \
  tar \
  unzip \
  git \
  wget \
  curl
```

### 2.5 Swap off, permanently

Kubelet will not start with swap enabled.

```bash
swapoff -a
sed -i '/swap/d' /etc/fstab
free -m      # Swap line must read 0 0 0
```

### 2.6 Kernel parameters

These are the values the RAC prerequisites specify. Setting them now saves repeating it on
the workers later; they are harmless on the operator and control plane nodes.

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

Do **not** set `vm.nr_hugepages` here. HugePages get configured on the workers only, in phase
B, and reserving 6 GB now would starve the phase A pods for no reason.

### 2.7 Clock source and time service

Oracle recommends TSC as the clock source in virtual environments, and Clusterware is unhappy
without it.

```bash
cat /sys/devices/system/clocksource/clocksource0/available_clocksource
echo "tsc" > /sys/devices/system/clocksource/clocksource0/current_clocksource
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
```

Make it survive reboot, and disable transparent hugepages while you are in the same file:

```bash
sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 numa=off transparent_hugepage=never clocksource=tsc"/' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg
```

Time sync:

```bash
systemctl enable --now chronyd
chronyc tracking
```

### 2.8 Firewall

OCNE's installer opens what it needs. Leave firewalld running and let `olcnectl` manage it.
If you hit unexplained cluster networking failures in phase 5, this is the first thing to
test by stopping it:

```bash
systemctl status firewalld
```

### 2.9 SSH key for the operator node

Phase 5 needs passwordless SSH from `ocne-op` to every node. Generate the key in the template
so all clones share the same authorized key, then the operator node keeps the private half.

```bash
ssh-keygen -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

Allow root login over SSH, which `olcnectl provision` needs:

```bash
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd
```

### 2.10 Clean up and shut down

Remove the machine identity so clones do not collide on DHCP leases or machine IDs.

```bash
dnf clean all
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /etc/NetworkManager/system-connections/*
history -c
shutdown -h now
```

Then detach the ISO from the host:

```powershell
VBoxManage storageattach ol9-golden --storagectl "IDE" --port 0 --device 0 --type dvddrive --medium none
```

**Gate:** `uname -r` is 5.15.x, swap is 0, clocksource is tsc, chronyd running, SELinux
enforcing, VM powered off.

**Snapshot point `00-golden`.** Take it now, before cloning.

---

## Phase 3 — Clone and configure the four VMs

### 3.1 Clone

```powershell
VBoxManage clonevm ol9-golden --name ocne-op  --register --mode machine
VBoxManage clonevm ol9-golden --name ocne-cp1 --register --mode machine
VBoxManage clonevm ol9-golden --name ocne-w1  --register --mode machine
VBoxManage clonevm ol9-golden --name ocne-w2  --register --mode machine
```

### 3.2 Size each VM and attach networks

```powershell
$BR = "Intel(R) Ethernet Connection (2) I219-V"   # your adapter name from step 0.6

# operator node
VBoxManage modifyvm ocne-op --memory 4096 --cpus 2
VBoxManage modifyvm ocne-op --nic1 bridged --bridgeadapter1 "$BR"

# control plane
VBoxManage modifyvm ocne-cp1 --memory 6144 --cpus 4
VBoxManage modifyvm ocne-cp1 --nic1 bridged --bridgeadapter1 "$BR"

# worker 1
VBoxManage modifyvm ocne-w1 --memory 20480 --cpus 8
VBoxManage modifyvm ocne-w1 --nic1 bridged --bridgeadapter1 "$BR"
VBoxManage modifyvm ocne-w1 --nic2 intnet --intnet2 racpriv1 --nicpromisc2 allow-all --nictype2 virtio
VBoxManage modifyvm ocne-w1 --nic3 intnet --intnet3 racpriv2 --nicpromisc3 allow-all --nictype3 virtio

# worker 2
VBoxManage modifyvm ocne-w2 --memory 20480 --cpus 8
VBoxManage modifyvm ocne-w2 --nic1 bridged --bridgeadapter1 "$BR"
VBoxManage modifyvm ocne-w2 --nic2 intnet --intnet2 racpriv1 --nicpromisc2 allow-all --nictype2 virtio
VBoxManage modifyvm ocne-w2 --nic3 intnet --intnet3 racpriv2 --nicpromisc3 allow-all --nictype3 virtio
```

`--nicpromisc allow-all` on the two internal networks is mandatory. Without it macvlan frames
are dropped and the RAC interconnect never comes up, with no obvious error. The bridged
adapter does **not** need promiscuous mode; leave it at the default `deny`.

### 3.3 Per-node identity

Boot one VM at a time, log in on the console, and set the hostname plus a static address on
the bridged interface.

| VM | hostname | example IP |
|---|---|---|
| ocne-op | `ocne-op.lab.local` | 192.168.1.210 |
| ocne-cp1 | `ocne-cp1.lab.local` | 192.168.1.211 |
| ocne-w1 | `ocne-w1.lab.local` | 192.168.1.221 |
| ocne-w2 | `ocne-w2.lab.local` | 192.168.1.222 |

Confirm the bridged interface name first; it is normally `enp0s3`, but check rather than assume:

```bash
ip -br link
```

Then, editing the top two lines for each node:

```bash
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

After this, each VM should be pingable from your Windows host and from anything else on the LAN.

### 3.4 Private interfaces on the workers, no IP

The two interconnect NICs carry **no IP address**. Multus exposes them inside the pod as
`eth1` and `eth2`. They need to be up, with MTU 9000, and nothing else. On both workers:

```bash
# identify the two internal-network interfaces
ip -br link

# with one bridged NIC these are usually enp0s8 and enp0s9; substitute yours
nmcli con add type ethernet ifname enp0s8 con-name priv1 ipv4.method disabled ipv6.method disabled mtu 9000
nmcli con add type ethernet ifname enp0s9 con-name priv2 ipv4.method disabled ipv6.method disabled mtu 9000
nmcli con up priv1
nmcli con up priv2

ip -br addr    # priv1 and priv2 show UP with no address
```

Write down which interface name maps to which internal network. Phase C's Multus
configuration references them by name, and if `racpriv1` is `enp0s8` on w1 but `enp0s9` on
w2, the interconnect silently splits.

### 3.5 Host resolution on all four nodes

```bash
cat >> /etc/hosts <<'EOF'
192.168.1.210  ocne-op.lab.local   ocne-op
192.168.1.211  ocne-cp1.lab.local  ocne-cp1
192.168.1.221  ocne-w1.lab.local   ocne-w1
192.168.1.222  ocne-w2.lab.local   ocne-w2
EOF
```

Add the same four lines to `C:\Windows\System32\drivers\etc\hosts` on your Windows host, and
to any other machine you plan to drive the cluster from. Your home router will not resolve
`.lab.local` names.

### 3.6 Verify SSH from the operator node

From `ocne-op`:

```bash
for h in ocne-op ocne-cp1 ocne-w1 ocne-w2; do
  echo "--- $h"
  ssh -o StrictHostKeyChecking=no root@$h hostname
done
```

All four must answer without a password prompt. This is what `olcnectl provision` relies on
in phase 5.

**Gate:** all four VMs up, static IPs correct, every node pings every other by short name,
passwordless root SSH from ocne-op to all four, workers show two address-less UP interfaces.

Verify with `./scripts/check-gate.sh 3`.

---

## Phase 4 — Storage

All VMs powered off for 4.1 through 4.4.

### 4.1 Worker data disks (private, thin)

110 GB each, holding `/var/lib/containers` plus headroom.

```powershell
VBoxManage createmedium disk --filename D:\VMs\ocne-w1\ocne-w1-data.vdi --size 112640 --format VDI
VBoxManage storageattach ocne-w1 --storagectl "SATA" --port 1 --device 0 --type hdd --medium D:\VMs\ocne-w1\ocne-w1-data.vdi

VBoxManage createmedium disk --filename D:\VMs\ocne-w2\ocne-w2-data.vdi --size 112640 --format VDI
VBoxManage storageattach ocne-w2 --storagectl "SATA" --port 1 --device 0 --type hdd --medium D:\VMs\ocne-w2\ocne-w2-data.vdi
```

### 4.2 NFS disk on the operator node

```powershell
VBoxManage createmedium disk --filename D:\VMs\ocne-op\ocne-op-nfs.vdi --size 153600 --format VDI
VBoxManage storageattach ocne-op --storagectl "SATA" --port 1 --device 0 --type hdd --medium D:\VMs\ocne-op\ocne-op-nfs.vdi
```

150 GB: it carries the staged media (~20 GB) and both nodes' Oracle homes (~60 GB installed),
with room for phase A datafiles.

### 4.3 Shared ASM disks

Fixed-size and shareable. VirtualBox refuses `shareable` on a dynamically allocated disk, so
this consumes 100 GB immediately.

```powershell
VBoxManage createmedium disk --filename D:\VMs\shared\asm1.vdi --size 40960 --format VDI --variant Fixed
VBoxManage createmedium disk --filename D:\VMs\shared\asm2.vdi --size 40960 --format VDI --variant Fixed
VBoxManage createmedium disk --filename D:\VMs\shared\asm3.vdi --size 20480 --format VDI --variant Fixed

VBoxManage modifymedium disk D:\VMs\shared\asm1.vdi --type shareable
VBoxManage modifymedium disk D:\VMs\shared\asm2.vdi --type shareable
VBoxManage modifymedium disk D:\VMs\shared\asm3.vdi --type shareable
```

Attach all three to **both workers**, same ports on each so device letters line up:

```powershell
foreach ($vm in @("ocne-w1","ocne-w2")) {
  VBoxManage storageattach $vm --storagectl "SATA" --port 2 --device 0 --type hdd --medium D:\VMs\shared\asm1.vdi --mtype shareable
  VBoxManage storageattach $vm --storagectl "SATA" --port 3 --device 0 --type hdd --medium D:\VMs\shared\asm2.vdi --mtype shareable
  VBoxManage storageattach $vm --storagectl "SATA" --port 4 --device 0 --type hdd --medium D:\VMs\shared\asm3.vdi --mtype shareable
}
```

### 4.4 Stable device names

`/dev/sdc` is not a promise. Give each shared disk a serial number so `/dev/disk/by-id/`
links appear, and reference those in the PersistentVolumes later.

```powershell
foreach ($vm in @("ocne-w1","ocne-w2")) {
  VBoxManage setextradata $vm "VBoxInternal/Devices/ahci/0/Config/Port2/SerialNumber" "asmdisk0001"
  VBoxManage setextradata $vm "VBoxInternal/Devices/ahci/0/Config/Port3/SerialNumber" "asmdisk0002"
  VBoxManage setextradata $vm "VBoxInternal/Devices/ahci/0/Config/Port4/SerialNumber" "asmdisk0003"
}
```

Boot both workers and confirm:

```bash
ls -l /dev/disk/by-id/ | grep asmdisk
lsblk
```

You should see five block devices on each worker: `sda` 40 G (OS), `sdb` 110 G (data), `sdc`
40 G, `sdd` 40 G, `sde` 20 G. **Leave sdc, sdd and sde completely alone.** No partition table,
no filesystem, no LVM. ASM claims them in phase B.

### 4.5 Worker data disk layout

On **both workers**:

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

### 4.6 NFS server on ocne-op

```bash
# on ocne-op
pvcreate /dev/sdb
vgcreate vg_nfs /dev/sdb
lvcreate -l 100%FREE -n lv_export vg_nfs
mkfs.xfs /dev/vg_nfs/lv_export

mkdir -p /export
echo '/dev/vg_nfs/lv_export  /export  xfs  defaults  0 0' >> /etc/fstab
mount -a

mkdir -p /export/stage /export/oradata

# Oracle runs as 54321:54321 inside the pods
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
exportfs -v

firewall-cmd --permanent --add-service=nfs
firewall-cmd --permanent --add-service=rpc-bind
firewall-cmd --permanent --add-service=mountd
firewall-cmd --reload
```

`no_root_squash` matters. Without it the pods, running as uid 54321, fail on permissions in a
way that reads like an Oracle bug.

### 4.7 Mount the stage on both workers

```bash
setsebool -P virt_use_nfs on
mkdir -p /scratch/software/stage

echo 'ocne-op:/export/stage  /scratch/software/stage  nfs  rw,bg,hard,nointr,rsize=32768,wsize=32768,tcp,vers=3,timeo=600,actimeo=0  0 0' >> /etc/fstab
mount -a
df -h /scratch/software/stage
touch /scratch/software/stage/.probe && echo OK
```

Those mount options are the ones Oracle validates at instance startup. Getting them wrong
produces `ORA-27054`, which does not look like a mount problem at all. Use the same options
for the datafile export in phase A.

### 4.8 Stage the media, once

Copy the zips from Windows to `ocne-op:/export/stage` (WinSCP, or `scp` from a shell). Then,
on ocne-op:

```bash
cd /export/stage
ls -la
chmod 755 *.zip
chown 54321:54321 *.zip
```

Both workers now see the media at `/scratch/software/stage` with no second copy.

**Gate:** `lsblk` on each worker shows five devices with sdc/sdd/sde untouched,
`/var/lib/containers` and `/scratch` mounted, NFS stage mounted on both workers and writable,
media visible from both.

Verify with `./scripts/check-gate.sh 4`.

---

## Phase 5 — Install Oracle Cloud Native Environment 1.9

Stay on 1.9. Newer OCNE releases moved to an image-based, cluster-API provisioning model that
does not map onto a hand-built VirtualBox lab the way 1.9 does, and 1.9 is what the RAC
prerequisites target. It gives you Kubernetes 1.29, which matters for the cert-manager
version choice in phase 6.

### 5.1 Enable the OCNE repository on all four nodes

```bash
dnf install -y oracle-olcne-release-el9
dnf config-manager --set-enabled ol9_olcne19 ol9_addons ol9_baseos_latest ol9_appstream ol9_UEKR7
dnf config-manager --set-disabled ol9_olcne18 ol9_olcne17
```

If `dnf repolist | grep olcne` shows nothing, the release RPM name has changed; check
`yum.oracle.com/oracle-linux-9.html` for the current one.

### 5.2 Install the platform packages

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

### 5.3 Firewall rules

On **ocne-cp1** (control plane):

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

### 5.4 Provision the cluster

From **ocne-op**. This single command generates certificates, distributes them, configures
the API server and agents, and installs the Kubernetes module.

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

It runs for 10 to 20 minutes and is chatty. If it fails partway, it is generally safe to fix
the cause and re-run the same command.

### 5.5 Set up kubectl

On **ocne-cp1**:

```bash
mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc

kubectl get nodes -o wide
```

Copy the same config to ocne-op if you prefer driving everything from there:

```bash
# on ocne-op
mkdir -p $HOME/.kube
scp root@ocne-cp1:/etc/kubernetes/admin.conf $HOME/.kube/config
```

### 5.5b Drive the cluster from Windows or another device

This is what bridging bought you. Install kubectl on the host:

```powershell
winget install -e --id Kubernetes.kubectl
```

Copy the kubeconfig across (WinSCP, or `scp` from a shell), then point kubectl at it:

```powershell
mkdir $HOME\.kube
# copy admin.conf from ocne-cp1:/etc/kubernetes/admin.conf to $HOME\.kube\config
$env:KUBECONFIG = "$HOME\.kube\config"
kubectl get nodes
```

Check the `server:` line in that file. It should already point at the control plane's LAN
address, because kubeadm uses the node IP. If it says `127.0.0.1` or a name your host cannot
resolve, edit it to `https://192.168.1.211:6443`. The API server certificate includes both
the node IP and hostname, so either works.

NodePort services you create in phase A will be reachable at `192.168.1.221:<port>` and
`192.168.1.222:<port>` from any device in the house, which makes connecting SQL Developer or
sqlplus to the database straightforward.

**One security note.** The cluster is now exposed to every device on your home network,
including guests on the same Wi-Fi. Leave firewalld running on the nodes, keep the API
server's default authentication, and do not forward any of these ports from your router to
the internet.

### 5.6 Verify

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl version --short
```

Three nodes `Ready`. Check the `INTERNAL-IP` column: it must show your static LAN addresses,
not anything the router handed out. If a node registered on a DHCP address, its static
configuration did not take; fix it in NetworkManager, then set `--node-ip` in
`/var/lib/kubelet/kubeadm-flags.env` on that node and restart kubelet.

All pods in `kube-system` should be Running, including the Flannel and CoreDNS pods.

### 5.7 Label the workers

```bash
kubectl label node ocne-w1.lab.local node-role.kubernetes.io/worker=
kubectl label node ocne-w2.lab.local node-role.kubernetes.io/worker=
kubectl label node ocne-w1.lab.local raccluster=raccluster01
kubectl label node ocne-w2.lab.local raccluster=raccluster01
kubectl get nodes --show-labels | grep raccluster
```

The `raccluster` label is what the RAC controller's `workerNodeSelector` matches in phase C.
Setting it now costs nothing.

**Gate: three nodes Ready on the right IPs, all kube-system pods Running.**

Verify with `./scripts/check-gate.sh 5`.

**Snapshot point `01-ocne-base`.** Shut down all four VMs and take it now. This is the
checkpoint you will return to most often.

```powershell
foreach ($vm in @("ocne-op","ocne-cp1","ocne-w1","ocne-w2")) {
  VBoxManage snapshot $vm take "01-ocne-base" --description "OCNE 1.9 cluster up, no operator yet"
}
```

Note: VirtualBox will refuse to snapshot the workers while shareable disks are attached. If
that happens, either detach the three ASM disks first and reattach after, or copy the whole
`D:\VMs` tree while everything is powered off. The file copy is cruder but always works.

---

## Phase 6 — Multus, cert-manager and the Database Operator

Run everything from wherever your kubeconfig lives (ocne-cp1 or ocne-op).

### 6.1 Add the Multus module

Multus layers on top of Flannel and gives pods extra interfaces. RAC needs it in phase C;
installing it now means the cluster is complete before you start using it.

From **ocne-op**:

```bash
olcnectl module create \
  --environment-name ocnelab \
  --module multus \
  --name mymultus \
  --multus-kubernetes-module ocnecluster

olcnectl module install --environment-name ocnelab --name mymultus
olcnectl module instances --environment-name ocnelab
```

Verify:

```bash
kubectl get pods -n kube-system -l app=multus
kubectl get crd | grep network-attachment
```

The NetworkAttachmentDefinitions themselves come later, in phase C, once you know your
interface names. The module just has to be present.

### 6.2 Install cert-manager, version-matched

The operator's webhooks need TLS certificates from cert-manager. **Do not paste the version
from the repo's README example.** OCNE 1.9 runs Kubernetes 1.29, and a current cert-manager
release will require something newer.

Check `cert-manager.io/docs/releases/` for a release whose supported range includes
Kubernetes 1.29, then:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/<VERSION>/cert-manager.yaml

kubectl get pods -n cert-manager -w
```

All three pods (`cert-manager`, `cert-manager-cainjector`, `cert-manager-webhook`) must be
Running before you go on. The webhook is the one that takes longest.

### 6.3 Clone the operator repository

```bash
cd /root
git clone https://github.com/oracle/oracle-database-operator.git
cd oracle-database-operator
```

### 6.4 Create the namespaces

```bash
kubectl create ns rac
kubectl create ns sidb
```

`sidb` is for phase A, `rac` for phases B and C.

### 6.5 Generate and apply a namespace-scoped install

Namespace scope is the default and the recommended option: it limits the operator to the
namespaces you name. Generate RBAC and `WATCH_NAMESPACE` from one list so they cannot drift
apart.

```bash
scripts/generate-namespace-install.sh oracle-database-operator-system,sidb,rac

kubectl apply -f dist/install/oracle-database-operator-rbac.yaml
kubectl apply -f dist/install/oracle-database-operator-system.yaml
```

### 6.6 Apply the optional cluster-scoped RBAC

Each of these grants one specific capability the later phases need. Review them before
applying; they are cluster-scoped.

```bash
# NodePort connect strings (phase A and C)
kubectl apply -f rbac/node-rbac.yaml

# storage expansion for block volumes (phase B and C)
kubectl apply -f rbac/storage-class-rbac.yaml

# read PersistentVolumes (phase A custom scripts)
kubectl apply -f rbac/persistent-volume-rbac.yaml

# create/delete PVs for ASM (phase B and C) — required for RAC
kubectl apply -f docs/rac/rbac/pv-rbac.yaml

# read NetworkAttachmentDefinitions (phase C) — required for RAC with Multus
kubectl apply -f rbac/multus-rbac.yaml
```

### 6.7 Verify the installation

```bash
kubectl rollout status deployment/oracle-database-operator-controller-manager \
  -n oracle-database-operator-system --timeout=300s

kubectl get pods -n oracle-database-operator-system -o wide
```

You should see three controller-manager replicas Running.

Permissions, checked one namespace at a time (the `-n` flag does not take a comma-separated
list):

```bash
for ns in oracle-database-operator-system sidb rac; do
  echo "--- $ns"
  kubectl auth can-i list singleinstancedatabases.database.oracle.com \
    --as=system:serviceaccount:oracle-database-operator-system:oracle-database-operator-controller-manager \
    -n "$ns"
done
```

CRDs and webhooks:

```bash
kubectl get crd | grep -E 'database.oracle.com|observability.oracle.com|network.oracle.com'
kubectl get mutatingwebhookconfiguration mutating-webhook-configuration
kubectl get validatingwebhookconfiguration validating-webhook-configuration
```

You want to see `singleinstancedatabases`, `dataguardbrokers`, `oraclerestarts`,
`racdatabases`, `lrpdbs` and friends in that CRD list. Those are the controllers your phases
A, B and C will drive.

Controller logs, for a clean start:

```bash
kubectl logs deployment/oracle-database-operator-controller-manager \
  -n oracle-database-operator-system -c manager --tail=50
```

### 6.8 Image pull secret for Oracle Container Registry

Phase A needs the Enterprise Edition image, which is licence-gated. Create the secret in both
namespaces now:

```bash
for ns in sidb rac; do
  kubectl create secret docker-registry oracle-container-registry-secret \
    --docker-server=container-registry.oracle.com \
    --docker-username='<your-oracle-sso-email>' \
    --docker-password='<your-oracle-sso-password>' \
    -n "$ns"
done
```

If you have not accepted the licence in the web UI (step 1.4), this secret is valid and the
pull still fails.

**Gate: three controller-manager pods Running, all three `can-i` checks return yes, CRDs and
both webhook configurations present.**

Verify with `./scripts/check-gate.sh 6`.

**Snapshot point `02-operator-installed`.**

```powershell
foreach ($vm in @("ocne-op","ocne-cp1","ocne-w1","ocne-w2")) {
  VBoxManage snapshot $vm take "02-operator-installed" --description "OraOperator + Multus + cert-manager"
}
```

---

## Checkpoints and what comes next

### Snapshot points

| Name | Taken after | Why you will come back to it |
|---|---|---|
| `00-golden` | phase 2, before cloning | rebuild any node from scratch |
| `01-ocne-base` | phase 5 gate | cluster works, operator experiments not yet started |
| `02-operator-installed` | phase 6 gate | the baseline for all of phase A |
| `03-phase-a-done` | after Data Guard switchover works | before touching worker prep for ASM |
| `04-rac-prereqs` | after phase B1 worker prep | before the first RAC provision |

Snapshot all VMs together, always, including ocne-op once it holds NFS state. A rollback that
misses one leaves datafiles out of sync with the cluster's idea of them.

From phase 4 onward, VirtualBox snapshots may be refused on the workers because of the
shareable disks. Fallback: power everything off and copy the `D:\VMs` tree, including
`D:\VMs\shared`.

### Remaining phases

**Phase A — operator fluency, no Oracle infrastructure**

A1: a StorageClass. OCNE gives you none by default, and SIDB needs a PVC on day one. Rancher
local-path-provisioner is one manifest and enough for this. Note that a local-path PVC pins
its pod to one node, which matters when you want primary on w1 and standby on w2.

A2: `SingleInstanceDatabase` from the EE image. Then clone it, then patch it.

A3: standby SIDB plus `DataguardBroker`. Manual switchover both directions, then fast-start
failover with the observer. This is the phase that teaches you the operator: watch
`status.conditions`, delete pods and watch reconciliation, break a CR deliberately and read
the webhook rejection.

**Phase B — ASM, via Oracle Restart**

B1: the RAC worker prep in full. HugePages (`vm.nr_hugepages=3072`, not Oracle's 16384, on a
20 GB node), kubelet `--allowed-unsafe-sysctls`, the `rac-ocne.te` SELinux policy module,
`semanage fcontext` on the scratch paths, per-node directories owned 54321:54321, CVU
validation.

B2: `OracleRestart` using two of the shared disks as block-mode PVs. Single instance GI plus
ASM, no interconnect. Most of the RAC surface with a fraction of the failure modes.

B3: add and remove an ASM disk, using `asm3`.

**Phase C — RAC**

C1: the macvlan NetworkAttachmentDefinitions, using the interface names you recorded in step 3.4.

C2: **wipe the ASM disk headers first** (`dd if=/dev/zero of=/dev/sdc bs=1M count=100` on both
workers, for each disk). The prerequisites are explicit that ASM devices must not carry data
from previous uses, and skipping this produces a RAC failure that reads like an operator bug.

Then the secrets (`db-user-pass`, `ssh-key-secret`) and the two-node `RacDatabase` CR. Expect
hours, and expect the first attempt to fail somewhere in the GI install.

C3: scale-out to a third node will go Pending, since you have two workers. Watching that
scheduling failure is itself worth doing; you will not see a third instance join.

---

## Troubleshooting quick reference

| Symptom | Likely cause | Check |
|---|---|---|
| Everything is glacially slow, nodes drop out | Hyper-V still active | `systeminfo \| findstr Hyper-V` on Windows; Memory Integrity is the usual culprit |
| VMs will not start, or start with no network | USB adapter moved port or unplugged; `$BR` name stale | `VBoxManage list bridgedifs`, re-set `--bridgeadapter1` |
| Network dies mid-provision, recovers later | USB power management put the adapter to sleep | Device Manager power settings, USB selective suspend |
| Intermittent packet loss, random node evictions | traffic going over Wi-Fi instead of the USB NIC | `route print`; fix the interface metric |
| A node's IP changed after a reboot | static config did not take, or the address is inside the router's DHCP pool | `nmcli con show "$CON" \| grep ipv4.method` should read `manual` |
| Nodes register on the wrong `INTERNAL-IP` | kubelet picked a different interface | set `--node-ip` in `/var/lib/kubelet/kubeadm-flags.env`, restart kubelet |
| `olcnectl provision` fails on SSH | key or root login | `ssh root@<node> hostname` from ocne-op with no password |
| kubelet will not start | swap re-enabled by an update | `free -m`, then `swapoff -a` and check `/etc/fstab` |
| cert-manager webhook CrashLoopBackOff | version newer than Kubernetes 1.29 supports | pick a release matching 1.29 |
| Operator pods Running but a CR does nothing | namespace not in `WATCH_NAMESPACE` | the `kubectl auth can-i` loop in 6.7 |
| Image pull fails with auth error | licence not accepted, or secret missing | accept at container-registry.oracle.com, recreate the secret |
| Pod stuck Pending on a PVC | no StorageClass | `kubectl get sc` returns nothing until phase A1 |
| `ORA-27054` at instance startup | wrong NFS mount options | the option string in 4.7, exactly |
| Permission denied inside a pod on an NFS path | `no_root_squash` missing, or wrong ownership | `exportfs -v`, and `ls -n` should show 54321 |
| Permission denied inside a pod on a local path | SELinux context | `semanage fcontext` and `restorecon`, phase B1 |
| ASM disk group creation fails | leftover headers from a previous use | `dd if=/dev/zero of=/dev/sdX bs=1M count=100` |
| Shared disk will not attach | disk is dynamically allocated | must be `--variant Fixed` to be shareable |
| VirtualBox refuses a snapshot | shareable disks attached | detach ASM disks, or copy the tree with everything powered off |
| RAC interconnect never comes up | promiscuous mode off, or interface names differ between workers | `--nicpromisc allow-all` on nic2/nic3; compare `ip -br link` on both |

### Useful one-liners

```bash
# what is the operator actually doing
kubectl logs -f deployment/oracle-database-operator-controller-manager \
  -n oracle-database-operator-system -c manager

# why is this resource not progressing
kubectl describe <kind> <name> -n <ns>
kubectl get events -n <ns> --sort-by=.lastTimestamp

# node pressure
kubectl describe node ocne-w1.lab.local | grep -A5 Conditions

# what the cluster thinks it has
kubectl get sc,pv,pvc -A
```

The repo's own `TROUBLESHOOTING.md` and `docs/rac/provisioning/debugging.md` cover the
controller-specific failures in phases A through C.
