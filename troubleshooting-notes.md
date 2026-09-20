# OCNE 1.9 Lab Build - Troubleshooting Notes

This document captures all issues encountered during the lab build and their resolutions.

---

## Phase 0 - Windows Host Preparation

### No issues encountered
- Hyper-V was not enabled
- VirtualBox 7.2.18 already installed
- 921 GB free space available

---

## Phase 2 - Golden VM Build

### Issue: UEK8 kernel installed instead of UEK7

**Symptom:**
```bash
[root@ol9-golden ~]# uname -r
6.12.0-203.76.7.3.el9uek.x86_64
```

**Cause:** Oracle Linux 9.8 ships with UEK8 by default, but RAC prerequisites require UEK7 (5.15.x).

**Resolution:**
```bash
# Enable UEK7 repo, disable UEK8
dnf install -y dnf-utils
dnf config-manager --set-enabled ol9_UEKR7
dnf config-manager --set-disabled ol9_UEKR8

# Install UEK7 kernel (package name differs from UEK8)
dnf install -y kernel-uek-5.15.0-324.217.5.3.el9uek

# Set UEK7 as default boot kernel
grubby --set-default /boot/vmlinuz-5.15.0-324.217.5.3.el9uek.x86_64
reboot
```

**Verification:**
```bash
[root@ol9-golden ~]# uname -r
5.15.0-324.217.5.3.el9uek.x86_64
```

---

## Phase 3 - Clone and Configure VMs

### Issue: Network subnet mismatch

**Symptom:** lab.env had 192.168.1.0/24 but actual network was 192.168.137.0/24

**Cause:** The lab host was connected via Windows ICS (Internet Connection Sharing) which uses 192.168.137.0/24 by default.

**Resolution:** Updated lab.env with correct values:
```bash
BRIDGE_ADAPTER="Killer E3100G 2.5 Gigabit Ethernet Controller"
LAN_SUBNET="192.168.137.0/24"
LAN_GATEWAY="192.168.137.1"
OP_IP="192.168.137.210"
CP1_IP="192.168.137.211"
W1_IP="192.168.137.221"
W2_IP="192.168.137.222"
```

---

## Phase 4 - Storage

### Issue: Disk device ordering differs between workers

**Symptom:**
- ocne-w1: data disk is `/dev/sde`, ASM disks are `/dev/sdb`, `/dev/sdc`, `/dev/sdd`
- ocne-w2: data disk is `/dev/sdb`, ASM disks are `/dev/sdc`, `/dev/sdd`, `/dev/sde`

**Cause:** VirtualBox assigns device letters based on port order but it's not always consistent across VMs.

**Resolution:**
- Use different device paths per worker for LVM setup
- Use `/dev/disk/by-id/` links for ASM disks (consistent across both workers):
```bash
ls -l /dev/disk/by-id/ | grep asmdisk
# ata-VBOX_HARDDISK_asmdisk0001 -> consistent regardless of /dev/sdX
```

---

## Phase 5 - OCNE Installation

### Issue: olcnectl provision stuck - agents not starting

**Symptom:** `olcnectl provision` hung after showing "Install and enable olcne-agent" for all nodes.

**Cause:** Certificate files copied with wrong ownership (root:root) but olcne-agent runs as user `olcne` and couldn't read them.

**Agent log showing the error:**
```bash
[root@ocne-w1 ~]# ssh root@ocne-cp1 "journalctl -u olcne-agent --no-pager | tail -5"
Sep 19 16:22:50 ocne-cp1.lab.local olcne-agent[2233]: time=19/09/26 16:22:50 level=fatal msg=Could not initialize secrets manager: open /etc/olcne/certificates/node.cert: permission denied
```

**Certificate permissions before fix:**
```bash
[root@ocne-w1 ~]# ssh root@ocne-cp1 "ls -la /etc/olcne/certificates/"
-rw-------. 1 root  root  1208 Sep 19 16:04 ca.cert
-rw-------. 1 root  root  1379 Sep 19 16:04 node.cert
-rw-------. 1 root  root  1704 Sep 19 16:04 node.key
```

**Attempted Resolution 1 - Fix permissions (temporary):**
```bash
for h in ocne-cp1 ocne-w1 ocne-w2; do
  ssh root@$h "chown olcne:olcne /etc/olcne/certificates/*.cert /etc/olcne/certificates/*.key && chmod 644 /etc/olcne/certificates/*.cert && chmod 600 /etc/olcne/certificates/*.key && systemctl restart olcne-agent"
done
```

**Problem:** Each time `olcnectl provision` ran, it re-copied certificates with root ownership, overwriting the fix.

**Final Resolution - Run olcne-agent as root via systemd override:**
```bash
for h in ocne-cp1 ocne-w1 ocne-w2; do
  ssh root@$h "mkdir -p /etc/systemd/system/olcne-agent.service.d"
  ssh root@$h "echo -e '[Service]\nUser=root\nGroup=root' > /etc/systemd/system/olcne-agent.service.d/override.conf"
  ssh root@$h "systemctl daemon-reload && systemctl restart olcne-agent"
done
```

**Verification:**
```bash
[root@ocne-w1 ~]# for h in ocne-cp1 ocne-w1 ocne-w2; do
    ssh root@$h "systemctl status olcne-agent --no-pager | head -5"
  done
● olcne-agent.service - Agent for Oracle Linux Cloud Native Environments
     Loaded: loaded (/usr/lib/systemd/system/olcne-agent.service; enabled; preset: disabled)
    Drop-In: /etc/systemd/system/olcne-agent.service.d
             └─override.conf
     Active: active (running) since Sat 2026-09-19 16:33:28 EDT; 10s ago
```

---

### Issue: olcnectl provision command stuck even after agents running

**Cause:** The `olcnectl provision` command had already timed out or was in a bad state.

**Resolution:** Use manual step-by-step approach instead of all-in-one provision:

```bash
# Step 1: Create environment
olcnectl environment create \
  --api-server ocne-op.lab.local:8091 \
  --environment-name ocnelab \
  --update-config

# Step 2: Create Kubernetes module (with external IP restriction disabled)
olcnectl module create \
  --environment-name ocnelab \
  --module kubernetes \
  --name ocnecluster \
  --container-registry container-registry.oracle.com/olcne \
  --control-plane-nodes ocne-cp1.lab.local:8090 \
  --worker-nodes ocne-w1.lab.local:8090,ocne-w2.lab.local:8090 \
  --selinux enforcing \
  --restrict-service-externalip=false

# Step 3: Install the module
olcnectl module install --environment-name ocnelab --name ocnecluster
```

**Note:** The `--restrict-service-externalip=false` flag was required to avoid certificate errors:
```
kubernetes encountered error with restrict-service-externalip-ca-cert
  "restrict-service-externalip-ca-cert" may not be empty
```

---

## Phase 6 - Operator Installation

### Issue: cert-manager webhook unreachable

**Symptom:**
```bash
Error from server (InternalError): error when creating "...": Internal error occurred: failed calling webhook "webhook.cert-manager.io": failed to call webhook: Post "https://cert-manager-webhook.cert-manager.svc:443/validate?timeout=30s": dial tcp 10.110.8.221:443: connect: no route to host
```

**Diagnosis:**
```bash
# Check where cert-manager pods are running
[root@ocne-op ~]# kubectl get pods -n cert-manager -o wide
NAME                                       READY   STATUS    IP           NODE
cert-manager-webhook-69bb4fc6c-g6kl2       1/1     Running   10.244.1.4   ocne-w1.lab.local

# Test connectivity from control plane to pod
[root@ocne-op ~]# ssh root@ocne-cp1 "curl -k https://10.244.1.4:10250 2>&1 | head -3"
curl: (7) Failed to connect to 10.244.1.4 port 10250: No route to host

# Check if cni0/flannel interfaces are in trusted zone
[root@ocne-op ~]# ssh root@ocne-w1 "firewall-cmd --zone=trusted --list-all"
trusted
  interfaces:    # EMPTY - this is the problem!
```

**Cause:** The `cni0` and `flannel.1` interfaces were not added to the firewall's trusted zone, blocking pod-to-pod traffic.

**Resolution:**
```bash
# Add CNI interfaces to trusted zone on workers
ssh root@ocne-w1 "firewall-cmd --permanent --zone=trusted --add-interface=cni0 && firewall-cmd --permanent --zone=trusted --add-interface=flannel.1 && firewall-cmd --reload"
ssh root@ocne-w2 "firewall-cmd --permanent --zone=trusted --add-interface=cni0 && firewall-cmd --permanent --zone=trusted --add-interface=flannel.1 && firewall-cmd --reload"

# Add flannel interface on control plane
ssh root@ocne-cp1 "firewall-cmd --permanent --zone=trusted --add-interface=flannel.1 && firewall-cmd --reload"
```

**Verification:**
```bash
[root@ocne-op ~]# ssh root@ocne-cp1 "curl -k https://10.244.1.4:10250 2>&1 | head -3"
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100    19  100    19    0     0   1461      0 --:--:-- --:--:-- --:--:--  1583
```

**Then re-apply the operator manifest:**
```bash
kubectl apply -f /root/oracle-database-operator/dist/install/oracle-database-operator-system.yaml
```

---

## Network Topology Notes

### Lab Network Setup

The lab uses Windows Internet Connection Sharing (ICS):

```
Internet
    |
    v
[Other Workstation] -- WiFi --> Router (192.168.1.0/24)
    |
    | Ethernet (ICS creates 192.168.137.0/24)
    v
[Lab Host: 192.168.137.121]
    |
    | VirtualBox Bridged Networking
    v
+------------------+
| VMs:             |
| ocne-op:   .210  |
| ocne-cp1:  .211  |
| ocne-w1:   .221  |
| ocne-w2:   .222  |
+------------------+
```

**Key insight:** 192.168.137.0/24 is the default ICS subnet. Devices on the WiFi network (192.168.1.0/24) cannot directly reach the VMs unless they're also connected to the ICS network via Ethernet.

---

## Summary of Key Learnings

1. **UEK7 vs UEK8:** Oracle Linux 9.8 ships with UEK8, but RAC requires UEK7. The package naming differs between versions.

2. **olcne-agent permissions:** The agent runs as user `olcne` but `olcnectl provision` copies certificates as root. Workaround: run agent as root via systemd override.

3. **Manual vs automated provision:** When `olcnectl provision` hangs, use the step-by-step approach with `environment create`, `module create`, and `module install`.

4. **Flannel firewall rules:** The CNI interfaces (`cni0`, `flannel.1`) must be in the firewall's trusted zone for pod networking to work.

5. **External IP restriction:** For a lab, disable with `--restrict-service-externalip=false` to avoid needing additional certificates.
