# Oracle RAC Networking Deep Dive Guide

This document provides a comprehensive explanation of how networking is configured and wired up for Oracle RAC on Kubernetes with the Oracle Database Operator.

---

## Table of Contents

1. [Network Architecture Overview](#1-network-architecture-overview)
2. [The Four Network Layers](#2-the-four-network-layers)
3. [VirtualBox Network Configuration](#3-virtualbox-network-configuration)
4. [Kubernetes CNI Networking](#4-kubernetes-cni-networking)
5. [Macvlan Networks for RAC](#5-macvlan-networks-for-rac)
6. [Why Promiscuous Mode is Required](#6-why-promiscuous-mode-is-required)
7. [IP Address Allocation](#7-ip-address-allocation)
8. [SCAN and VIP Explained](#8-scan-and-vip-explained)
9. [Listener Architecture](#9-listener-architecture)
10. [DNS and Name Resolution](#10-dns-and-name-resolution)
11. [Network Flow Diagrams](#11-network-flow-diagrams)
12. [Troubleshooting Network Issues](#12-troubleshooting-network-issues)

---

## 1. Network Architecture Overview

Oracle RAC requires multiple network paths:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         RAC NETWORK REQUIREMENTS                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐          │
│  │  PUBLIC NETWORK │    │ PRIVATE NET #1  │    │ PRIVATE NET #2  │          │
│  │  (Client Access)│    │ (Interconnect)  │    │ (Redundant IC)  │          │
│  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘          │
│           │                      │                      │                    │
│           ▼                      ▼                      ▼                    │
│  • Database connections   • Cache Fusion        • Failover path             │
│  • SCAN listener          • Cluster heartbeat   • Load balancing            │
│  • VIP failover           • Block transfers     • Redundancy                │
│  • Client TNS             • GCS/GES messages    • HA guarantee              │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Why three networks?**
- **Public**: Clients connect here. VIPs fail over between nodes.
- **Private #1 (Interconnect)**: Cache Fusion block transfers, cluster heartbeat.
- **Private #2 (Redundant Interconnect)**: Prevents single point of failure.

---

## 2. The Four Network Layers

Your RAC deployment has four distinct networking layers:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│   LAYER 4: Oracle RAC Networking                                            │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  SCAN: 192.168.56.220-222  │  VIP1: 192.168.56.211                  │   │
│   │  VIP2: 192.168.56.212      │  Listeners on 1521                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                    ▲                                         │
│                                    │                                         │
│   LAYER 3: Macvlan (Multus) Networks                                        │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  rac-priv1 (192.168.57.0/24)  │  rac-priv2 (192.168.58.0/24)        │   │
│   │  Attached to: enp0s8          │  Attached to: enp0s9                │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                    ▲                                         │
│                                    │                                         │
│   LAYER 2: Kubernetes Pod Networking (Calico CNI)                           │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  Pod CIDR: 10.244.0.0/16  │  Service CIDR: 10.96.0.0/12             │   │
│   │  Primary pod interface: eth0 (Calico)                               │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                    ▲                                         │
│                                    │                                         │
│   LAYER 1: VirtualBox Host Networking                                       │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  Adapter 1 (NAT): Internet access                                   │   │
│   │  Adapter 2 (Host-Only vboxnet0): 192.168.56.0/24 - Public           │   │
│   │  Adapter 3 (Internal rac-priv1): 192.168.57.0/24 - Private #1       │   │
│   │  Adapter 4 (Internal rac-priv2): 192.168.58.0/24 - Private #2       │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. VirtualBox Network Configuration

### 3.1 Network Adapter Layout

Each worker node VM has 4 network adapters:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     VIRTUALBOX VM NETWORK ADAPTERS                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                        ocne-worker1 / ocne-worker2                   │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │                                                                      │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │    │
│  │  │   Adapter 1  │  │   Adapter 2  │  │   Adapter 3  │  │ Adapter 4│ │    │
│  │  │     NAT      │  │  Host-Only   │  │   Internal   │  │ Internal │ │    │
│  │  │              │  │   vboxnet0   │  │  rac-priv1   │  │rac-priv2 │ │    │
│  │  │              │  │              │  │              │  │          │ │    │
│  │  │   enp0s3     │  │   enp0s8     │  │   enp0s9     │  │ enp0s10  │ │    │
│  │  │ 10.0.2.x     │  │192.168.56.x  │  │192.168.57.x  │  │192.168.  │ │    │
│  │  │  (DHCP)      │  │  (Static)    │  │  (Static)    │  │  58.x    │ │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────┘ │    │
│  │       │                   │                  │              │        │    │
│  │       ▼                   ▼                  ▼              ▼        │    │
│  │   Internet           Public Net         Private #1     Private #2   │    │
│  │   Access             (Clients)         (Interconnect)  (Redundant)  │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 VirtualBox Configuration Commands

```powershell
# View VM network configuration
VBoxManage showvminfo ocne-worker1 --machinereadable | findstr "nic\|hostonlyadapter\|intnet"

# What you'll see:
# nic1="nat"
# nic2="hostonly"
# hostonlyadapter2="vboxnet0"
# nicpromisc2="allow-all"         <-- CRITICAL for macvlan
# nic3="intnet"
# intnet3="rac-priv1"
# nicpromisc3="allow-all"         <-- CRITICAL for macvlan
# nic4="intnet"
# intnet4="rac-priv2"
# nicpromisc4="allow-all"         <-- CRITICAL for macvlan
```

### 3.3 Internal Network vs Host-Only

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    NETWORK TYPE COMPARISON                                   │
├───────────────────────┬─────────────────────┬───────────────────────────────┤
│       Feature         │     Host-Only       │        Internal Network       │
├───────────────────────┼─────────────────────┼───────────────────────────────┤
│ Host can access?      │        YES          │            NO                 │
│ VMs can talk?         │        YES          │    YES (same intnet name)     │
│ External access?      │        NO           │            NO                 │
│ Use case              │   Public network    │   Private interconnects       │
│ Our usage             │   vboxnet0 (public) │   rac-priv1, rac-priv2        │
└───────────────────────┴─────────────────────┴───────────────────────────────┘
```

**Why Internal Networks for Interconnect?**
- Complete isolation - no host interference
- Direct VM-to-VM communication at layer 2
- Lower latency for Cache Fusion traffic
- Security - interconnect traffic never leaves VirtualBox

---

## 4. Kubernetes CNI Networking

### 4.1 Calico CNI (Primary Network)

Calico provides the default pod networking:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CALICO NETWORK TOPOLOGY                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ocne-worker1                              ocne-worker2                     │
│   ┌─────────────────────────┐              ┌─────────────────────────┐      │
│   │   Pod: racnode1-0       │              │   Pod: racnode2-0       │      │
│   │   ┌─────────────────┐   │              │   ┌─────────────────┐   │      │
│   │   │ eth0            │   │              │   │ eth0            │   │      │
│   │   │ 10.244.1.x      │   │              │   │ 10.244.2.x      │   │      │
│   │   └────────┬────────┘   │              │   └────────┬────────┘   │      │
│   └────────────┼────────────┘              └────────────┼────────────┘      │
│                │                                        │                    │
│                ▼                                        ▼                    │
│   ┌─────────────────────────┐              ┌─────────────────────────┐      │
│   │ cali* veth pair         │              │ cali* veth pair         │      │
│   │ (virtual ethernet)      │              │ (virtual ethernet)      │      │
│   └────────────┬────────────┘              └────────────┬────────────┘      │
│                │                                        │                    │
│                ▼                                        ▼                    │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │                     Calico IPIP Tunnel or BGP                       │    │
│   │                   (Routes between worker nodes)                     │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│   Pod CIDR: 10.244.0.0/16                                                   │
│   - ocne-worker1 gets: 10.244.1.0/24                                        │
│   - ocne-worker2 gets: 10.244.2.0/24                                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Service Networking

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       KUBERNETES SERVICE TYPES                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         ClusterIP Service                               │ │
│  │  Name: racdb-scan-svc                                                   │ │
│  │  IP: 10.96.x.x (internal only)                                          │ │
│  │  Accessible: Only from within cluster                                   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         NodePort Service                                │ │
│  │  Name: racdb-lsnr1-svc, racdb-lsnr2-svc                                 │ │
│  │  Ports: 32521, 32522 (mapped to 1521 inside pod)                        │ │
│  │  Accessible: <any-node-ip>:32521                                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  Client Connection Example:                                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ sqlplus sys@192.168.56.31:32521/RACDB as sysdba                     │    │
│  │         ^^^^^^^^^^^^^^ ^^^^^ ^^^^                                    │    │
│  │         worker1 IP     port  service name                           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Macvlan Networks for RAC

### 5.1 What is Macvlan?

Macvlan allows pods to have their own MAC addresses and appear as separate hosts on a physical network:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           MACVLAN EXPLAINED                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  WITHOUT Macvlan (Normal CNI):            WITH Macvlan (RAC Private Net):   │
│                                                                              │
│  ┌─────────────┐                          ┌─────────────┐                   │
│  │    Pod      │                          │    Pod      │                   │
│  │  ┌───────┐  │                          │  ┌───────┐  │                   │
│  │  │ eth0  │  │                          │  │ ens1  │  │  <-- macvlan iface│
│  │  │10.244.│  │                          │  │192.168│  │                   │
│  │  │ x.x   │  │                          │  │.57.x  │  │                   │
│  │  └───┬───┘  │                          │  └───┬───┘  │                   │
│  └──────┼──────┘                          └──────┼──────┘                   │
│         │                                        │                           │
│         ▼                                        ▼                           │
│  ┌──────────────┐                         ┌──────────────┐                  │
│  │ veth pair +  │                         │  macvlan     │                  │
│  │ iptables NAT │                         │  (direct L2) │                  │
│  └──────────────┘                         └──────────────┘                  │
│         │                                        │                           │
│         ▼                                        ▼                           │
│  ┌──────────────┐                         ┌──────────────┐                  │
│  │ Host NIC     │                         │ Host NIC     │                  │
│  │ (shared MAC) │                         │ (pod gets    │                  │
│  │              │                         │  own MAC!)   │                  │
│  └──────────────┘                         └──────────────┘                  │
│                                                                              │
│  Pod appears as:                          Pod appears as:                   │
│  Behind NAT, no direct L2                 INDEPENDENT HOST on network!     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 NetworkAttachmentDefinition Resources

These Kubernetes CRDs define the macvlan networks:

```yaml
# rac-priv1 - First private interconnect
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: rac-priv1
  namespace: rac
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "macvlan",
    "master": "enp0s8",           # <-- Host interface to bind to
    "mode": "bridge",
    "ipam": {
      "type": "static"            # <-- IP assigned statically by pod
    }
  }'
```

```yaml
# rac-priv2 - Second private interconnect (redundancy)
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: rac-priv2
  namespace: rac
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "macvlan",
    "master": "enp0s9",           # <-- Different host interface
    "mode": "bridge",
    "ipam": {
      "type": "static"
    }
  }'
```

### 5.3 Multus: The Multi-Network CNI

Multus acts as a meta-CNI that allows pods to have multiple network interfaces:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            MULTUS ARCHITECTURE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│                    kubelet calls Multus CNI                                  │
│                              │                                               │
│                              ▼                                               │
│                    ┌─────────────────┐                                      │
│                    │     MULTUS      │                                      │
│                    │   (Meta-CNI)    │                                      │
│                    └────────┬────────┘                                      │
│                             │                                                │
│            ┌────────────────┼────────────────┐                              │
│            │                │                │                               │
│            ▼                ▼                ▼                               │
│     ┌────────────┐   ┌────────────┐   ┌────────────┐                        │
│     │   Calico   │   │  Macvlan   │   │  Macvlan   │                        │
│     │  (Default) │   │ rac-priv1  │   │ rac-priv2  │                        │
│     └─────┬──────┘   └─────┬──────┘   └─────┬──────┘                        │
│           │                │                │                                │
│           ▼                ▼                ▼                                │
│        ┌──────┐        ┌──────┐        ┌──────┐                             │
│        │ eth0 │        │ ens1 │        │ ens2 │                             │
│        └──────┘        └──────┘        └──────┘                             │
│           │                │                │                                │
│           └────────────────┴────────────────┘                               │
│                            │                                                 │
│                            ▼                                                 │
│                    ┌─────────────┐                                          │
│                    │  RAC Pod    │                                          │
│                    │ (3 NICs!)   │                                          │
│                    └─────────────┘                                          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.4 Pod Annotation for Multiple Networks

The RacDatabase operator adds this annotation to pods:

```yaml
annotations:
  k8s.v1.cni.cncf.io/networks: |
    [
      {"name": "rac-priv1", "interface": "ens1"},
      {"name": "rac-priv2", "interface": "ens2"}
    ]
```

---

## 6. Why Promiscuous Mode is Required

### 6.1 The Problem Without Promiscuous Mode

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     WITHOUT PROMISCUOUS MODE                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Network Packet arrives with:                                                │
│  Destination MAC: AA:BB:CC:DD:EE:FF  (Pod's macvlan MAC)                    │
│                                                                              │
│                    │                                                         │
│                    ▼                                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    VirtualBox NIC                                    │    │
│  │         Host MAC: 08:00:27:XX:XX:XX                                  │    │
│  │                                                                      │    │
│  │    Question: Is AA:BB:CC:DD:EE:FF == 08:00:27:XX:XX:XX ?            │    │
│  │    Answer: NO!                                                       │    │
│  │    Action: *** DROP PACKET ***                                       │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Result: Pod's macvlan interface NEVER RECEIVES TRAFFIC!                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 The Solution: Promiscuous Mode

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      WITH PROMISCUOUS MODE                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Network Packet arrives with:                                                │
│  Destination MAC: AA:BB:CC:DD:EE:FF  (Pod's macvlan MAC)                    │
│                                                                              │
│                    │                                                         │
│                    ▼                                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    VirtualBox NIC                                    │    │
│  │         Host MAC: 08:00:27:XX:XX:XX                                  │    │
│  │         Mode: PROMISCUOUS (--nicpromisc2 allow-all)                  │    │
│  │                                                                      │    │
│  │    Promiscuous Mode: ACCEPT ALL PACKETS regardless of MAC!          │    │
│  │    Action: *** ACCEPT PACKET ***                                     │    │
│  │                                                                      │    │
│  └──────────────────────────────┬──────────────────────────────────────┘    │
│                                 │                                            │
│                                 ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    Linux Kernel (Worker Node)                        │    │
│  │                                                                      │    │
│  │   Routes packet to macvlan interface with matching MAC               │    │
│  │                                                                      │    │
│  └──────────────────────────────┬──────────────────────────────────────┘    │
│                                 │                                            │
│                                 ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    Pod Network Namespace                             │    │
│  │         Interface ens1, MAC: AA:BB:CC:DD:EE:FF                       │    │
│  │                                                                      │    │
│  │    *** PACKET RECEIVED SUCCESSFULLY! ***                             │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Enabling Promiscuous Mode in VirtualBox

```powershell
# Enable promiscuous mode on all relevant adapters (VM must be powered off)
VBoxManage modifyvm ocne-worker1 --nicpromisc2 allow-all  # Host-only (public)
VBoxManage modifyvm ocne-worker1 --nicpromisc3 allow-all  # rac-priv1
VBoxManage modifyvm ocne-worker1 --nicpromisc4 allow-all  # rac-priv2

VBoxManage modifyvm ocne-worker2 --nicpromisc2 allow-all
VBoxManage modifyvm ocne-worker2 --nicpromisc3 allow-all
VBoxManage modifyvm ocne-worker2 --nicpromisc4 allow-all
```

---

## 7. IP Address Allocation

### 7.1 Complete IP Address Map

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         IP ADDRESS ALLOCATION                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  NETWORK: 192.168.56.0/24 (Host-Only / Public)                              │
│  ─────────────────────────────────────────────                              │
│  192.168.56.1      │ VirtualBox Host Adapter                                │
│  192.168.56.10     │ ocne-op (Operator Node)                                │
│  192.168.56.21     │ ocne-cp1 (Control Plane)                               │
│  192.168.56.31     │ ocne-worker1 (Worker 1)                                │
│  192.168.56.32     │ ocne-worker2 (Worker 2)                                │
│  192.168.56.211    │ racnode1-0 VIP (Virtual IP, can float)                 │
│  192.168.56.212    │ racnode2-0 VIP (Virtual IP, can float)                 │
│  192.168.56.220    │ SCAN IP #1                                              │
│  192.168.56.221    │ SCAN IP #2                                              │
│  192.168.56.222    │ SCAN IP #3                                              │
│                                                                              │
│  NETWORK: 192.168.57.0/24 (Internal / Private Interconnect #1)              │
│  ─────────────────────────────────────────────────────────────              │
│  192.168.57.31     │ ocne-worker1 (enp0s9)                                  │
│  192.168.57.32     │ ocne-worker2 (enp0s9)                                  │
│  192.168.57.211    │ racnode1-0 ens1 (pod interconnect #1)                  │
│  192.168.57.212    │ racnode2-0 ens1 (pod interconnect #1)                  │
│                                                                              │
│  NETWORK: 192.168.58.0/24 (Internal / Private Interconnect #2)              │
│  ─────────────────────────────────────────────────────────────              │
│  192.168.58.31     │ ocne-worker1 (enp0s10)                                 │
│  192.168.58.32     │ ocne-worker2 (enp0s10)                                 │
│  192.168.58.211    │ racnode1-0 ens2 (pod interconnect #2)                  │
│  192.168.58.212    │ racnode2-0 ens2 (pod interconnect #2)                  │
│                                                                              │
│  NETWORK: 10.244.0.0/16 (Kubernetes Pod CIDR - Calico)                      │
│  ─────────────────────────────────────────────────────                      │
│  10.244.1.x        │ Pods on ocne-worker1                                   │
│  10.244.2.x        │ Pods on ocne-worker2                                   │
│  10.244.1.53       │ racnode1-0 eth0 (example)                              │
│  10.244.2.53       │ racnode2-0 eth0 (example)                              │
│                                                                              │
│  NETWORK: 10.96.0.0/12 (Kubernetes Service CIDR)                            │
│  ────────────────────────────────────────────────                           │
│  10.96.0.1         │ kubernetes API service                                 │
│  10.96.0.10        │ kube-dns (CoreDNS)                                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Where IPs Are Configured

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     IP CONFIGURATION LOCATIONS                               │
├────────────────────────────────────┬────────────────────────────────────────┤
│           IP Type                  │        Configuration Location          │
├────────────────────────────────────┼────────────────────────────────────────┤
│ Worker node IPs                    │ /etc/sysconfig/network-scripts/        │
│ (192.168.56.31, etc.)              │ or NetworkManager                      │
├────────────────────────────────────┼────────────────────────────────────────┤
│ Pod IPs (10.244.x.x)               │ Assigned by Calico IPAM                │
│                                    │ (automatic)                            │
├────────────────────────────────────┼────────────────────────────────────────┤
│ Macvlan IPs (192.168.57/58.x)      │ RacDatabase CR → Pod env vars →        │
│                                    │ configured by init scripts             │
├────────────────────────────────────┼────────────────────────────────────────┤
│ VIP IPs (192.168.56.211/212)       │ RacDatabase CR → Grid Infrastructure   │
│                                    │ → managed by Oracle Clusterware        │
├────────────────────────────────────┼────────────────────────────────────────┤
│ SCAN IPs (192.168.56.220-222)      │ RacDatabase CR → Grid Infrastructure   │
│                                    │ → DNS or GNS                           │
└────────────────────────────────────┴────────────────────────────────────────┘
```

---

## 8. SCAN and VIP Explained

### 8.1 What is SCAN?

SCAN (Single Client Access Name) provides a single DNS name for client connections:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SCAN EXPLAINED                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Client TNS: (DESCRIPTION=(ADDRESS=(HOST=racdb-scan)(PORT=1521))...)        │
│                                                                              │
│                              │                                               │
│                              ▼                                               │
│                    ┌─────────────────┐                                      │
│                    │   DNS Lookup    │                                      │
│                    │   racdb-scan    │                                      │
│                    └────────┬────────┘                                      │
│                             │                                                │
│         ┌───────────────────┼───────────────────┐                           │
│         │                   │                   │                            │
│         ▼                   ▼                   ▼                            │
│  ┌────────────┐      ┌────────────┐      ┌────────────┐                     │
│  │192.168.56. │      │192.168.56. │      │192.168.56. │                     │
│  │    220     │      │    221     │      │    222     │                     │
│  └─────┬──────┘      └─────┬──────┘      └─────┬──────┘                     │
│        │                   │                   │                             │
│        └───────────────────┴───────────────────┘                            │
│                            │                                                 │
│                            ▼                                                 │
│              Client picks ONE (round-robin)                                  │
│                            │                                                 │
│                            ▼                                                 │
│                    ┌─────────────────┐                                      │
│                    │  SCAN Listener  │                                      │
│                    │  (Port 1521)    │                                      │
│                    └────────┬────────┘                                      │
│                             │                                                │
│               Redirects to best instance                                     │
│                             │                                                │
│              ┌──────────────┴──────────────┐                                │
│              ▼                             ▼                                 │
│      ┌─────────────┐               ┌─────────────┐                          │
│      │   RACDB1    │               │   RACDB2    │                          │
│      │ (Instance1) │               │ (Instance2) │                          │
│      └─────────────┘               └─────────────┘                          │
│                                                                              │
│  Benefits:                                                                   │
│  • Single connection string for all clients                                  │
│  • Automatic load balancing                                                  │
│  • Transparent failover                                                      │
│  • No client reconfiguration when nodes added/removed                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 What is VIP?

VIP (Virtual IP) provides fast failover for database connections:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                               VIP FAILOVER                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  NORMAL OPERATION:                                                           │
│  ─────────────────                                                          │
│                                                                              │
│  racnode1-0                              racnode2-0                          │
│  ┌─────────────────────────┐            ┌─────────────────────────┐         │
│  │  VIP: 192.168.56.211    │            │  VIP: 192.168.56.212    │         │
│  │  Instance: RACDB1       │            │  Instance: RACDB2       │         │
│  │  Status: ONLINE         │            │  Status: ONLINE         │         │
│  └─────────────────────────┘            └─────────────────────────┘         │
│                                                                              │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  AFTER NODE1 FAILURE:                                                        │
│  ────────────────────                                                       │
│                                                                              │
│  racnode1-0                              racnode2-0                          │
│  ┌─────────────────────────┐            ┌─────────────────────────┐         │
│  │  █████ FAILED █████     │            │  VIP: 192.168.56.212    │         │
│  │  Instance: DOWN         │───────────▶│  VIP: 192.168.56.211 ◀──│ FLOATED │
│  │  Status: OFFLINE        │            │  Instance: RACDB2       │         │
│  └─────────────────────────┘            │  Status: ONLINE         │         │
│                                          └─────────────────────────┘         │
│                                                                              │
│  What happens:                                                               │
│  1. Clusterware detects node1 failure                                        │
│  2. VIP 192.168.56.211 moves to node2 (< 30 seconds)                        │
│  3. Clients connected to .211 get TCP RST (instant failure detection)       │
│  4. Application reconnects, gets directed to RACDB2                          │
│                                                                              │
│  Why VIP is faster than relying on node IP:                                  │
│  • Node IP timeout: 2+ minutes (TCP keepalive)                               │
│  • VIP failover: < 30 seconds                                                │
│  • Client gets immediate "connection reset" signal                           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. Listener Architecture

### 9.1 RAC Listeners

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          RAC LISTENER ARCHITECTURE                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Each RAC node runs TWO types of listeners:                                  │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                        SCAN LISTENER                                 │    │
│  │                                                                      │    │
│  │  Name: LISTENER_SCAN1, LISTENER_SCAN2, LISTENER_SCAN3               │    │
│  │  Runs on: Whichever node owns the SCAN VIP                          │    │
│  │  Listens on: SCAN IPs (192.168.56.220-222:1521)                     │    │
│  │  Purpose: Accept new connections, redirect to local listeners       │    │
│  │  Managed by: Oracle Clusterware (CRS)                               │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                        LOCAL LISTENER                                │    │
│  │                                                                      │    │
│  │  Name: LISTENER_RACNODE1, LISTENER_RACNODE2                         │    │
│  │  Runs on: Each node's VIP                                           │    │
│  │  Listens on: VIP (192.168.56.211/212:1521)                          │    │
│  │  Purpose: Handle redirected connections, serve the local instance   │    │
│  │  Managed by: Oracle Clusterware (CRS)                               │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Connection Flow:                                                            │
│                                                                              │
│    Client                                                                    │
│      │                                                                       │
│      │ 1. Connect to SCAN:1521                                               │
│      ▼                                                                       │
│    SCAN Listener                                                             │
│      │                                                                       │
│      │ 2. Picks best instance based on load                                  │
│      │ 3. Returns REDIRECT to local listener                                 │
│      ▼                                                                       │
│    Local Listener (VIP)                                                      │
│      │                                                                       │
│      │ 4. Hands off to database instance                                     │
│      ▼                                                                       │
│    Database Instance (RACDB1 or RACDB2)                                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 Kubernetes Service Mapping

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    KUBERNETES SERVICE TO LISTENER MAPPING                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ Service: racdb-scan-svc (ClusterIP)                                   │  │
│  │ ClusterIP: 10.96.x.x                                                  │  │
│  │ Port: 1521                                                            │  │
│  │ Selects: pods with label app=racdb                                    │  │
│  │ Use: Internal cluster access to SCAN                                  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ Service: racdb-lsnr1-svc (NodePort)                                   │  │
│  │ NodePort: 32521                                                       │  │
│  │ Target: racnode1-0:1521                                               │  │
│  │ Use: External access to instance 1                                    │  │
│  │ Connect: 192.168.56.31:32521 (via worker1 IP)                         │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ Service: racdb-lsnr2-svc (NodePort)                                   │  │
│  │ NodePort: 32522                                                       │  │
│  │ Target: racnode2-0:1521                                               │  │
│  │ Use: External access to instance 2                                    │  │
│  │ Connect: 192.168.56.31:32522 (via any worker IP)                      │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Connection Examples:                                                        │
│                                                                              │
│  # From within cluster (another pod):                                        │
│  sqlplus sys@racdb-scan-svc.rac.svc.cluster.local:1521/RACDB as sysdba      │
│                                                                              │
│  # From Windows host (external):                                             │
│  sqlplus sys@192.168.56.31:32521/RACDB as sysdba                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 10. DNS and Name Resolution

### 10.1 The CoreDNS Problem with Macvlan

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  WHY RAC PODS CAN'T REACH COREDNS                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Normal Pod (using Calico only):                                             │
│  ────────────────────────────────                                           │
│                                                                              │
│  ┌───────────────────┐          ┌───────────────────┐                       │
│  │    Normal Pod     │          │     CoreDNS       │                       │
│  │   eth0: 10.244.x  │ ───────▶ │   10.96.0.10      │                       │
│  │   via Calico CNI  │   OK!    │   (ClusterIP)     │                       │
│  └───────────────────┘          └───────────────────┘                       │
│                                                                              │
│  Path: Pod eth0 → Calico → kube-proxy iptables → CoreDNS                    │
│  Works because Calico routes to Service CIDR (10.96.0.0/12)                 │
│                                                                              │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  RAC Pod (with macvlan):                                                     │
│  ───────────────────────                                                    │
│                                                                              │
│  ┌───────────────────┐          ┌───────────────────┐                       │
│  │     RAC Pod       │          │     CoreDNS       │                       │
│  │   eth0: 10.244.x  │          │   10.96.0.10      │                       │
│  │   ens1: 192.168.  │          │                   │                       │
│  │         57.x      │ ────X    │                   │                       │
│  └───────────────────┘  FAIL!   └───────────────────┘                       │
│                                                                              │
│  Problem: RAC scripts add routes that send traffic via macvlan              │
│  interfaces instead of eth0. Packets to 10.96.0.10 go out ens1,            │
│  which has no route to the Kubernetes Service CIDR!                         │
│                                                                              │
│  Symptoms:                                                                   │
│  • "PRVG-5820: Failed to retrieve IP address of host"                       │
│  • DNS resolution timeout                                                    │
│  • Cannot resolve FQDN like racnode1-0.rac.svc.cluster.local               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 10.2 The /etc/hosts Workaround

Since RAC pods can't reach CoreDNS, we add static entries:

```bash
# Inside each RAC pod, add entries for the other node(s):

# On racnode1-0:
echo "10.244.2.53 racnode2-0.rac.svc.cluster.local racnode2-0" >> /etc/hosts

# On racnode2-0:
echo "10.244.1.53 racnode1-0.rac.svc.cluster.local racnode1-0" >> /etc/hosts
```

### 10.3 Complete Name Resolution Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     NAME RESOLUTION IN RAC CLUSTER                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                          /etc/hosts                                  │    │
│  │   (First priority - checked before DNS)                              │    │
│  │                                                                      │    │
│  │   10.244.1.53  racnode1-0.rac.svc.cluster.local racnode1-0          │    │
│  │   10.244.2.53  racnode2-0.rac.svc.cluster.local racnode2-0          │    │
│  │   192.168.57.211 racnode1-0-priv1                                   │    │
│  │   192.168.57.212 racnode2-0-priv1                                   │    │
│  │   192.168.58.211 racnode1-0-priv2                                   │    │
│  │   192.168.58.212 racnode2-0-priv2                                   │    │
│  │   192.168.56.211 racnode1-0-vip                                     │    │
│  │   192.168.56.212 racnode2-0-vip                                     │    │
│  │   192.168.56.220 racdb-scan                                         │    │
│  │   192.168.56.221 racdb-scan                                         │    │
│  │   192.168.56.222 racdb-scan                                         │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                          /etc/resolv.conf                            │    │
│  │   (Fallback to CoreDNS - but broken for macvlan pods)               │    │
│  │                                                                      │    │
│  │   search rac.svc.cluster.local svc.cluster.local cluster.local      │    │
│  │   nameserver 10.96.0.10                                             │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Resolution Order:                                                           │
│  1. /etc/hosts (static entries we added)                                     │
│  2. DNS (10.96.0.10) - fails for macvlan pods                               │
│                                                                              │
│  Our workaround: Add ALL required names to /etc/hosts so DNS is never       │
│  needed for RAC internal communication.                                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 11. Network Flow Diagrams

### 11.1 Client Connection Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CLIENT CONNECTION FLOW                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  STEP 1: Client initiates connection                                        │
│  ──────────────────────────────────                                         │
│                                                                              │
│  ┌──────────────┐                                                           │
│  │ SQL*Plus     │  sqlplus sys@192.168.56.31:32521/RACDB                    │
│  │ (Windows)    │                                                           │
│  └──────┬───────┘                                                           │
│         │                                                                    │
│         │ TCP SYN to 192.168.56.31:32521                                    │
│         ▼                                                                    │
│                                                                              │
│  STEP 2: Kubernetes NodePort routing                                         │
│  ────────────────────────────────────                                       │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                      ocne-worker1 (192.168.56.31)                     │   │
│  │                                                                       │   │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │   │
│  │  │  kube-proxy (iptables)                                          │ │   │
│  │  │                                                                  │ │   │
│  │  │  Rule: -A KUBE-NODEPORTS -p tcp --dport 32521 -j KUBE-SVC-xxx   │ │   │
│  │  │  Action: DNAT to 10.244.1.53:1521 (pod IP)                      │ │   │
│  │  │                                                                  │ │   │
│  │  └───────────────────────────────┬─────────────────────────────────┘ │   │
│  │                                  │                                    │   │
│  └──────────────────────────────────┼────────────────────────────────────┘   │
│                                     │                                        │
│         │ Packet rewritten: dst = 10.244.1.53:1521                          │
│         ▼                                                                    │
│                                                                              │
│  STEP 3: Calico routes to pod                                                │
│  ────────────────────────────                                               │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                         racnode1-0 pod                                │   │
│  │                                                                       │   │
│  │  ┌───────────────────────────────────────────────────────────────┐   │   │
│  │  │  eth0: 10.244.1.53                                            │   │   │
│  │  │  Packet arrives on port 1521                                   │   │   │
│  │  └───────────────────────────────┬───────────────────────────────┘   │   │
│  │                                  │                                    │   │
│  │  ┌───────────────────────────────┴───────────────────────────────┐   │   │
│  │  │  LISTENER_RACNODE1                                             │   │   │
│  │  │  Listening on 0.0.0.0:1521                                     │   │   │
│  │  │  Accepts connection, hands to RACDB1 instance                  │   │   │
│  │  └───────────────────────────────────────────────────────────────┘   │   │
│  │                                                                       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 11.2 Cache Fusion (Interconnect) Traffic

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    CACHE FUSION TRAFFIC FLOW                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Scenario: RACDB2 needs a data block currently in RACDB1's buffer cache     │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                          racnode2-0                                  │    │
│  │                                                                      │    │
│  │  ┌────────────────────────────────────────────────────────────────┐ │    │
│  │  │  RACDB2 Instance                                                │ │    │
│  │  │                                                                 │ │    │
│  │  │  1. Query needs block from USERS tablespace                     │ │    │
│  │  │  2. Block not in local buffer cache                             │ │    │
│  │  │  3. GCS (Global Cache Service) check: block held by RACDB1     │ │    │
│  │  │  4. Request block transfer via interconnect                     │ │    │
│  │  │                                                                 │ │    │
│  │  └──────────────────────────┬─────────────────────────────────────┘ │    │
│  │                             │                                       │    │
│  │           ┌─────────────────┴─────────────────┐                    │    │
│  │           │                                   │                     │    │
│  │           ▼                                   ▼                     │    │
│  │   ┌───────────────┐                   ┌───────────────┐            │    │
│  │   │     ens1      │                   │     ens2      │            │    │
│  │   │ 192.168.57.212│                   │ 192.168.58.212│            │    │
│  │   │ (Primary IC)  │                   │ (Backup IC)   │            │    │
│  │   └───────┬───────┘                   └───────────────┘            │    │
│  │           │                                                        │    │
│  └───────────┼────────────────────────────────────────────────────────┘    │
│              │                                                              │
│              │  UDP/TCP traffic via rac-priv1 macvlan                      │
│              │  Direct Layer 2 communication (no routing needed)           │
│              │                                                              │
│  ┌───────────┼────────────────────────────────────────────────────────┐    │
│  │           │                          racnode1-0                     │    │
│  │           │                                                         │    │
│  │   ┌───────┴───────┐                   ┌───────────────┐            │    │
│  │   │     ens1      │                   │     ens2      │            │    │
│  │   │ 192.168.57.211│                   │ 192.168.58.211│            │    │
│  │   │ (Primary IC)  │                   │ (Backup IC)   │            │    │
│  │   └───────┬───────┘                   └───────────────┘            │    │
│  │           │                                                        │    │
│  │  ┌────────┴───────────────────────────────────────────────────────┐│    │
│  │  │  RACDB1 Instance                                                ││    │
│  │  │                                                                 ││    │
│  │  │  5. Receives block request                                      ││    │
│  │  │  6. Sends block contents via interconnect                       ││    │
│  │  │  7. RACDB2 receives block, query continues                      ││    │
│  │  │                                                                 ││    │
│  │  └─────────────────────────────────────────────────────────────────┘│    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Timing: Block transfer takes microseconds on local network                 │
│  Protocol: Oracle proprietary over UDP (primarily)                          │
│  Why 2 interfaces? Redundancy - if ens1 fails, traffic uses ens2           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 11.3 Complete Network Path Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  COMPLETE NETWORK PATH SUMMARY                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Traffic Type          │ Source            │ Destination        │ Path      │
│  ──────────────────────┼───────────────────┼────────────────────┼─────────  │
│                        │                   │                    │           │
│  Client → Database     │ Windows Host      │ RAC Pod            │           │
│  (External)            │ 192.168.56.1      │ racnode1-0         │           │
│                        │                   │                    │           │
│    192.168.56.1 ───▶ 192.168.56.31:32521 ───▶ iptables DNAT     │           │
│                        ───▶ 10.244.1.53:1521 ───▶ pod eth0       │           │
│                                                                  │           │
│  ──────────────────────┼───────────────────┼────────────────────┼─────────  │
│                        │                   │                    │           │
│  Pod → Pod             │ racnode1-0        │ racnode2-0         │           │
│  (Calico Network)      │ 10.244.1.53       │ 10.244.2.53        │           │
│                        │                   │                    │           │
│    10.244.1.53 (eth0) ───▶ Calico routing ───▶ 10.244.2.53 (eth0)│          │
│    (Used for Kubernetes service discovery, health checks)       │           │
│                                                                  │           │
│  ──────────────────────┼───────────────────┼────────────────────┼─────────  │
│                        │                   │                    │           │
│  Cache Fusion          │ racnode1-0        │ racnode2-0         │           │
│  (Interconnect #1)     │ 192.168.57.211    │ 192.168.57.212     │           │
│                        │                   │                    │           │
│    192.168.57.211 (ens1) ───▶ macvlan ───▶ 192.168.57.212 (ens1)│           │
│    Direct L2, no routing, lowest latency                        │           │
│                                                                  │           │
│  ──────────────────────┼───────────────────┼────────────────────┼─────────  │
│                        │                   │                    │           │
│  Cache Fusion          │ racnode1-0        │ racnode2-0         │           │
│  (Interconnect #2)     │ 192.168.58.211    │ 192.168.58.212     │           │
│                        │                   │                    │           │
│    192.168.58.211 (ens2) ───▶ macvlan ───▶ 192.168.58.212 (ens2)│           │
│    Redundant path, used if #1 fails                             │           │
│                                                                  │           │
│  ──────────────────────┼───────────────────┼────────────────────┼─────────  │
│                        │                   │                    │           │
│  VIP Communication     │ Client            │ VIP address        │           │
│                        │ 192.168.56.1      │ 192.168.56.211     │           │
│                        │                   │                    │           │
│    192.168.56.1 ───▶ 192.168.56.211 (VIP owned by current node) │           │
│    VIP floats between nodes on failure                          │           │
│                                                                  │           │
└─────────────────────────────────────────────────────────────────┴───────────┘
```

---

## 12. Troubleshooting Network Issues

### 12.1 Common Issues and Fixes

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    NETWORK TROUBLESHOOTING GUIDE                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ISSUE: Pods can't communicate via macvlan interfaces                       │
│  ─────────────────────────────────────────────────────                      │
│  Symptoms:                                                                   │
│  - ping 192.168.57.212 fails from racnode1-0                                │
│  - Grid Infrastructure install hangs                                         │
│                                                                              │
│  Diagnosis:                                                                  │
│  # Check promiscuous mode on VirtualBox                                      │
│  VBoxManage showvminfo ocne-worker1 --machinereadable | findstr nicpromisc  │
│  # Should show: nicpromisc2="allow-all", nicpromisc3="allow-all", etc.      │
│                                                                              │
│  Fix:                                                                        │
│  VBoxManage modifyvm ocne-worker1 --nicpromisc3 allow-all                   │
│                                                                              │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  ISSUE: DNS resolution fails inside RAC pods                                 │
│  ───────────────────────────────────────────                                │
│  Symptoms:                                                                   │
│  - "PRVG-5820: Failed to retrieve IP address of host"                       │
│  - nslookup racnode2-0 times out                                            │
│                                                                              │
│  Diagnosis:                                                                  │
│  # Inside pod:                                                               │
│  cat /etc/resolv.conf                                                        │
│  ping 10.96.0.10  # CoreDNS - will likely fail                              │
│  ip route         # Check if default route goes via macvlan                  │
│                                                                              │
│  Fix:                                                                        │
│  # Add static /etc/hosts entries                                             │
│  echo "10.244.2.53 racnode2-0.rac.svc.cluster.local racnode2-0" >> /etc/hosts│
│                                                                              │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  ISSUE: External clients can't connect to database                          │
│  ─────────────────────────────────────────────────                          │
│  Symptoms:                                                                   │
│  - Connection timeout to 192.168.56.31:32521                                │
│                                                                              │
│  Diagnosis:                                                                  │
│  # Check service exists                                                      │
│  kubectl get svc -n rac                                                      │
│                                                                              │
│  # Check endpoints                                                           │
│  kubectl get endpoints -n rac                                                │
│                                                                              │
│  # Check listener inside pod                                                 │
│  kubectl exec -it racnode1-0 -n rac -- lsnrctl status                       │
│                                                                              │
│  Fix:                                                                        │
│  - Ensure listener is running                                                │
│  - Ensure service selector matches pod labels                                │
│  - Ensure firewall allows NodePort                                           │
│                                                                              │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  ISSUE: Cache Fusion errors / slow inter-instance communication             │
│  ───────────────────────────────────────────────────────────────            │
│  Symptoms:                                                                   │
│  - "ORA-29740: evicted by member"                                            │
│  - High gc cr block receive time in AWR                                      │
│                                                                              │
│  Diagnosis:                                                                  │
│  # Check interconnect IPs                                                    │
│  oifcfg getif                                                                │
│                                                                              │
│  # Check network latency                                                     │
│  ping -c 100 192.168.57.212  # from node1 to node2 interconnect              │
│                                                                              │
│  # Check for packet loss                                                     │
│  ip -s link show ens1                                                        │
│                                                                              │
│  Fix:                                                                        │
│  - Ensure both private networks are configured                               │
│  - Check for MTU mismatches                                                  │
│  - Verify VirtualBox internal network settings                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 12.2 Diagnostic Commands

```bash
# ==============================================================================
# NETWORK DIAGNOSTIC COMMANDS
# ==============================================================================

# --- On Worker Node (as root) ---

# View all network interfaces
ip addr show

# View routing table
ip route

# Check if macvlan interfaces exist for pod
ip link show | grep macvlan

# View network namespaces (each pod has one)
ip netns list

# --- Inside RAC Pod ---

# View pod interfaces
ip addr show

# Expected output:
# eth0: 10.244.x.x (Calico - primary)
# ens1: 192.168.57.x (macvlan - private #1)
# ens2: 192.168.58.x (macvlan - private #2)

# Check routes
ip route
# Note: Look for routes via ens1/ens2 - these are added by RAC setup

# Test connectivity to other node
ping -c 3 192.168.57.212    # Private interconnect #1
ping -c 3 192.168.58.212    # Private interconnect #2

# Check /etc/hosts
cat /etc/hosts

# Check DNS config
cat /etc/resolv.conf

# Test DNS (will fail due to macvlan)
nslookup racnode2-0

# --- Kubernetes Commands ---

# View pod network annotations
kubectl get pod racnode1-0 -n rac -o jsonpath='{.metadata.annotations}'

# View NetworkAttachmentDefinitions
kubectl get net-attach-def -n rac -o yaml

# Check Multus logs
kubectl logs -n kube-system -l app=multus

# View services
kubectl get svc -n rac -o wide

# View endpoints (show backend pod IPs)
kubectl get endpoints -n rac

# --- Oracle RAC Commands ---

# View interconnect configuration
oifcfg getif

# View cluster interconnect
olsnodes -n -i

# Check network-related CRS resources
crsctl stat res -t | grep -i net
```

---

## Summary: How It All Connects

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PUTTING IT ALL TOGETHER                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  The RAC networking stack has these key relationships:                       │
│                                                                              │
│  1. VirtualBox provides Layer 1/2:                                           │
│     └── Host-only adapter (vboxnet0) for public network                     │
│     └── Internal networks (rac-priv1, rac-priv2) for interconnects          │
│     └── Promiscuous mode allows macvlan MAC addresses                        │
│                                                                              │
│  2. Kubernetes provides Layer 3/4 (with help):                               │
│     └── Calico CNI: Default pod networking (eth0)                           │
│     └── Multus CNI: Allows additional interfaces                            │
│     └── Macvlan CNI: Creates ens1, ens2 for RAC private networks            │
│     └── Services: NodePort/ClusterIP for external access                    │
│     └── kube-proxy: iptables rules for service routing                      │
│                                                                              │
│  3. Oracle RAC uses the networks:                                            │
│     └── Public (via eth0 + macvlan): Client connections, SCAN, VIP          │
│     └── Private #1 (ens1): Primary interconnect for Cache Fusion            │
│     └── Private #2 (ens2): Redundant interconnect                           │
│     └── Listeners: SCAN (cluster-wide) + Local (per-node VIP)               │
│                                                                              │
│  4. DNS workaround:                                                          │
│     └── Macvlan pods can't reach CoreDNS (10.96.0.10)                       │
│     └── Solution: Static /etc/hosts entries for all RAC hosts               │
│                                                                              │
│  5. Connection flow:                                                         │
│     └── Client → NodePort (32521) → kube-proxy DNAT → pod eth0 → Listener  │
│                                                                              │
│  6. Cache Fusion flow:                                                       │
│     └── Instance1 ens1 → macvlan → rac-priv1 internal net → Instance2 ens1  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         QUICK REFERENCE                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  NETWORKS:                                                                   │
│  ─────────                                                                  │
│  192.168.56.0/24  │ Public (Host-Only vboxnet0)                             │
│  192.168.57.0/24  │ Private #1 (Internal rac-priv1)                         │
│  192.168.58.0/24  │ Private #2 (Internal rac-priv2)                         │
│  10.244.0.0/16    │ Kubernetes Pods (Calico)                                │
│  10.96.0.0/12     │ Kubernetes Services                                     │
│                                                                              │
│  POD INTERFACES:                                                             │
│  ───────────────                                                            │
│  eth0  │ Calico (10.244.x.x) - k8s default                                  │
│  ens1  │ Macvlan rac-priv1 (192.168.57.x)                                   │
│  ens2  │ Macvlan rac-priv2 (192.168.58.x)                                   │
│                                                                              │
│  KEY IPs:                                                                    │
│  ────────                                                                   │
│  VIP1: 192.168.56.211  │  VIP2: 192.168.56.212                              │
│  SCAN: 192.168.56.220-222                                                   │
│  CoreDNS: 10.96.0.10 (unreachable from RAC pods!)                           │
│                                                                              │
│  CONNECTION:                                                                 │
│  ───────────                                                                │
│  External: sqlplus sys@192.168.56.31:32521/RACDB as sysdba                  │
│  Internal: sqlplus sys@racdb-scan-svc:1521/RACDB as sysdba                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

*Document created: Oracle RAC 19c on Kubernetes (OCNE 1.9) - Networking Guide*
