# OCNE 1.9 Oracle Database Lab - Architecture Diagrams

## Overall Lab Infrastructure

```mermaid
flowchart TB
    subgraph HOST["Windows Host (Lab Machine)"]
        VB[("VirtualBox 7.x")]
        KC["kubectl"]
    end

    subgraph BRIDGE["Bridged Network - 192.168.137.0/24"]
        direction LR
    end

    subgraph VMS["VirtualBox VMs"]
        direction LR
        OP["ocne-op<br/>Operator + NFS<br/>192.168.137.210"]
        CP["ocne-cp1<br/>Control Plane<br/>192.168.137.211"]
        W1["ocne-w1<br/>Worker 1<br/>192.168.137.221"]
        W2["ocne-w2<br/>Worker 2<br/>192.168.137.222"]
    end

    VB --> BRIDGE
    KC --> BRIDGE
    BRIDGE --> OP
    BRIDGE --> CP
    BRIDGE --> W1
    BRIDGE --> W2

    style HOST fill:#e1f5fe,stroke:#01579b
    style VMS fill:#f3e5f5,stroke:#4a148c
    style OP fill:#fff3e0,stroke:#e65100
    style CP fill:#e8f5e9,stroke:#1b5e20
    style W1 fill:#fce4ec,stroke:#880e4f
    style W2 fill:#fce4ec,stroke:#880e4f
```

---

## VM Specifications

```mermaid
flowchart LR
    subgraph OCNE_OP["ocne-op"]
        OP_SPEC["2 vCPU | 4 GB RAM<br/>40 GB OS<br/>150 GB NFS"]
    end

    subgraph OCNE_CP1["ocne-cp1"]
        CP_SPEC["4 vCPU | 16 GB RAM<br/>40 GB OS"]
    end

    subgraph OCNE_W1["ocne-w1"]
        W1_SPEC["8 vCPU | 20 GB RAM<br/>40 GB OS + 100 GB Data"]
    end

    subgraph OCNE_W2["ocne-w2"]
        W2_SPEC["8 vCPU | 20 GB RAM<br/>40 GB OS + 100 GB Data"]
    end

    subgraph SHARED["Shared ASM Disks"]
        ASM1["asm1.vdi<br/>40 GB"]
        ASM2["asm2.vdi<br/>40 GB"]
        ASM3["asm3.vdi<br/>20 GB"]
    end

    SHARED --> OCNE_W1
    SHARED --> OCNE_W2

    style OCNE_OP fill:#fff3e0,stroke:#e65100
    style OCNE_CP1 fill:#e8f5e9,stroke:#1b5e20
    style OCNE_W1 fill:#fce4ec,stroke:#880e4f
    style OCNE_W2 fill:#fce4ec,stroke:#880e4f
    style SHARED fill:#e3f2fd,stroke:#0d47a1
```

| VM | RAM | CPUs | Storage |
|---|---|---|---|
| ocne-op (.210) | 4 GB | 2 | 40GB OS + NFS export |
| ocne-cp1 (.211) | 16 GB | 4 | 40GB OS |
| ocne-w1 (.221) | 20 GB | 8 | 40GB OS + 100GB Data + ASM disks |
| ocne-w2 (.222) | 20 GB | 8 | 40GB OS + 100GB Data + ASM disks |

---

## Kubernetes Cluster Architecture

```mermaid
flowchart TB
    subgraph CP["Control Plane (ocne-cp1)"]
        direction TB
        API["kube-apiserver"]
        ETCD["etcd"]
        SCHED["scheduler"]
        CM["controller-manager"]
        DNS["CoreDNS"]
        FLANNEL["Flannel CNI"]
    end

    subgraph WORKERS["Worker Nodes"]
        direction LR
        subgraph W1["ocne-w1"]
            K1["kubelet"]
            C1["CRI-O"]
            P1["Application Pods"]
        end
        subgraph W2["ocne-w2"]
            K2["kubelet"]
            C2["CRI-O"]
            P2["Application Pods"]
        end
    end

    subgraph NAMESPACES["Cluster Namespaces"]
        direction LR
        NS_CERT["cert-manager<br/>TLS Certificates"]
        NS_OP["oracle-database-<br/>operator-system<br/>DB Operator"]
        NS_SIDB["sidb<br/>Phase A Workloads"]
        NS_RAC["rac<br/>Phase B/C Workloads"]
    end

    CP -->|"Flannel VXLAN<br/>10.244.0.0/16"| WORKERS
    WORKERS --> NAMESPACES

    style CP fill:#e8f5e9,stroke:#1b5e20
    style W1 fill:#fce4ec,stroke:#880e4f
    style W2 fill:#fce4ec,stroke:#880e4f
    style NS_CERT fill:#fff8e1,stroke:#ff6f00
    style NS_OP fill:#e3f2fd,stroke:#0d47a1
    style NS_SIDB fill:#f3e5f5,stroke:#4a148c
    style NS_RAC fill:#ffebee,stroke:#b71c1c
```

---

## Phase A: SIDB + Data Guard Architecture

```mermaid
flowchart TB
    subgraph DG["Data Guard Broker"]
        BROKER["DataguardBroker CR<br/>Protection: MaxPerformance<br/>FSFO: Disabled"]
    end

    subgraph PRIMARY["Primary Database (ocne-w1)"]
        direction TB
        SIDB_P["SingleInstanceDatabase CR<br/>SID: ORCL<br/>Role: PRIMARY"]
        POD_P["Pod: sidb-primary<br/>Image: enterprise:19.3.0.0<br/>CPU: 2-4 | RAM: 8-12 GB"]
        SVC_P["Service: NodePort<br/>Port: 1521"]
        SIDB_P --> POD_P --> SVC_P
    end

    subgraph STANDBY["Standby Database (ocne-w2)"]
        direction TB
        SIDB_S["SingleInstanceDatabase CR<br/>SID: ORCLS<br/>Role: PHYSICAL_STANDBY"]
        POD_S["Pod: sidb-standby<br/>Image: enterprise:19.3.0.0<br/>CPU: 2-4 | RAM: 8-12 GB"]
        SVC_S["Service: NodePort<br/>Port: 1521"]
        SIDB_S --> POD_S --> SVC_S
    end

    subgraph NFS["NFS Storage (ocne-op)"]
        direction LR
        PV_P["PV: sidb-primary-pv<br/>/export/oradata/sidb-primary<br/>100 GB"]
        PV_S["PV: sidb-standby-pv<br/>/export/oradata/sidb-standby<br/>100 GB"]
    end

    DG -->|"Manages"| PRIMARY
    DG -->|"Manages"| STANDBY
    PRIMARY <-->|"Redo Log<br/>Shipping"| STANDBY
    POD_P -->|"PVC Mount"| PV_P
    POD_S -->|"PVC Mount"| PV_S

    style DG fill:#e1f5fe,stroke:#01579b
    style PRIMARY fill:#c8e6c9,stroke:#2e7d32
    style STANDBY fill:#ffccbc,stroke:#e64a19
    style NFS fill:#fff3e0,stroke:#e65100
```

### Data Guard Data Flow

```mermaid
sequenceDiagram
    participant C as Client
    participant P as Primary (ORCL)
    participant S as Standby (ORCLS)
    participant B as DG Broker

    C->>P: SQL Transaction
    P->>P: Write Redo Log
    P->>S: Ship Redo (Async)
    S->>S: Apply Redo

    Note over B: Monitors both databases

    rect rgb(255, 235, 238)
        Note over P,S: Switchover (Manual)
        B->>P: Convert to Standby
        B->>S: Convert to Primary
    end
```

---

## Phase B: Oracle Restart + ASM Architecture

```mermaid
flowchart TB
    subgraph WORKER["Worker Node: ocne-w1"]
        subgraph OR_CR["OracleRestart CR"]
            direction TB
            subgraph POD["Pod: oradb1-0 (StatefulSet)"]
                direction TB
                subgraph HAS["Oracle Restart (HAS)"]
                    OHASD["ohasd.bin"]
                    CSSD["cssd"]
                    EVMD["evmd"]
                    ONS["ons"]
                end

                subgraph ASM_INST["+ASM Instance"]
                    ASM_PMON["asm_pmon"]
                    ASM_RBAL["asm_rbal"]
                end

                subgraph DB["Database: ORCL"]
                    DB_PMON["ora_pmon"]
                    DB_SMON["ora_smon"]
                    DB_LGWR["ora_lgwr"]
                    LSNR["LISTENER"]
                end

                subgraph HOMES["Oracle Homes"]
                    GRID["/u01/app/19c/grid<br/>Grid Infrastructure"]
                    DBHOME["/u01/app/oracle/product/19c/dbhome_1<br/>Database Home"]
                end
            end
        end
    end

    subgraph STORAGE["ASM Storage (+DATA)"]
        direction LR
        DISK1["asmdisk0001<br/>/dev/sdc<br/>40 GB"]
        DISK2["asmdisk0002<br/>/dev/sdd<br/>40 GB"]
    end

    POD --> STORAGE

    style WORKER fill:#fce4ec,stroke:#880e4f
    style POD fill:#e8eaf6,stroke:#3f51b5
    style HAS fill:#fff8e1,stroke:#ff6f00
    style ASM_INST fill:#e0f2f1,stroke:#00695c
    style DB fill:#c8e6c9,stroke:#2e7d32
    style STORAGE fill:#e3f2fd,stroke:#0d47a1
```

### Oracle Restart Resource Stack

```mermaid
flowchart LR
    subgraph RESOURCES["crsctl stat res -t"]
        direction TB
        R1["ora.cssd<br/>ONLINE"]
        R2["ora.evmd<br/>ONLINE"]
        R3["ora.ons<br/>ONLINE"]
        R4["ora.asm (+ASM)<br/>ONLINE"]
        R5["ora.DATA.dg<br/>ONLINE"]
        R6["ora.LISTENER<br/>ONLINE"]
        R7["ora.orcl.db<br/>ONLINE - Open"]
    end

    R1 --> R4
    R4 --> R5
    R5 --> R7
    R6 --> R7

    style R1 fill:#fff8e1,stroke:#ff6f00
    style R2 fill:#fff8e1,stroke:#ff6f00
    style R3 fill:#fff8e1,stroke:#ff6f00
    style R4 fill:#e0f2f1,stroke:#00695c
    style R5 fill:#e0f2f1,stroke:#00695c
    style R6 fill:#e1f5fe,stroke:#01579b
    style R7 fill:#c8e6c9,stroke:#2e7d32
```

---

## Network Connectivity

```mermaid
flowchart TB
    subgraph EXTERNAL["External Access"]
        CLIENT["SQL*Plus Client"]
    end

    subgraph K8S["Kubernetes Cluster"]
        subgraph SVC["Service Layer"]
            NP["NodePort Service<br/>:31521"]
            CS["ClusterIP Service"]
        end

        subgraph PODS["Pod Network (Flannel)"]
            POD1["sidb-primary<br/>10.244.1.x:1521"]
            POD2["sidb-standby<br/>10.244.2.x:1521"]
        end
    end

    CLIENT -->|"192.168.137.221:31521"| NP
    NP --> CS
    CS --> POD1

    POD1 <-->|"Flannel VXLAN<br/>10.244.0.0/16"| POD2

    style EXTERNAL fill:#e1f5fe,stroke:#01579b
    style SVC fill:#fff8e1,stroke:#ff6f00
    style PODS fill:#f3e5f5,stroke:#4a148c
```

### Connection Strings

```mermaid
flowchart LR
    subgraph CONNECT["Connection Methods"]
        direction TB
        EXT["External (NodePort)<br/>192.168.137.221:31521/ORCL"]
        INT["Internal (ClusterIP)<br/>oradb1-0.rac.svc:1521/ORCL"]
        DG["Data Guard<br/>sidb-primary.sidb.svc:1521"]
    end

    style CONNECT fill:#e8f5e9,stroke:#1b5e20
```

---

## Storage Architecture

```mermaid
flowchart TB
    subgraph PHASE_A["Phase A: NFS Storage"]
        direction TB
        NFS_SRV["ocne-op<br/>NFS Server"]
        NFS_EXP["/export/oradata"]

        subgraph NFS_DIRS["NFS Exports"]
            DIR1["sidb-primary/"]
            DIR2["sidb-standby/"]
        end

        NFS_SRV --> NFS_EXP --> NFS_DIRS

        subgraph NFS_OPTS["Mount Options"]
            OPTS["rw,sync<br/>no_root_squash<br/>Owner: 54321:54321"]
        end
    end

    subgraph PHASE_B["Phase B: ASM Block Storage"]
        direction TB
        subgraph VBOX["VirtualBox Shared Disks"]
            VDI1["asm1.vdi (40GB)"]
            VDI2["asm2.vdi (40GB)"]
            VDI3["asm3.vdi (20GB)"]
        end

        subgraph DEVICES["Block Devices"]
            DEV1["/dev/sdc"]
            DEV2["/dev/sdd"]
            DEV3["/dev/sde"]
        end

        subgraph ASM_DG["+DATA Diskgroup"]
            DG_INFO["Redundancy: EXTERNAL<br/>Total: ~80 GB<br/>Contents: ORCL database"]
        end

        VDI1 --> DEV1
        VDI2 --> DEV2
        VDI3 --> DEV3
        DEV1 --> ASM_DG
        DEV2 --> ASM_DG
    end

    style PHASE_A fill:#e8f5e9,stroke:#1b5e20
    style PHASE_B fill:#e3f2fd,stroke:#0d47a1
    style ASM_DG fill:#fff8e1,stroke:#ff6f00
```

### Storage Comparison

```mermaid
flowchart LR
    subgraph NFS_CHAR["NFS (Phase A)"]
        NFS1["Filesystem-based"]
        NFS2["Shared via network"]
        NFS3["Easy backups"]
        NFS4["Good for SIDB"]
    end

    subgraph ASM_CHAR["ASM (Phase B/C)"]
        ASM1["Block-based"]
        ASM2["Direct disk access"]
        ASM3["Built-in striping"]
        ASM4["Required for RAC"]
    end

    style NFS_CHAR fill:#e8f5e9,stroke:#1b5e20
    style ASM_CHAR fill:#e3f2fd,stroke:#0d47a1
```

---

## Oracle Database Operator Components

```mermaid
flowchart TB
    subgraph OPERATOR["oracle-database-operator-system Namespace"]
        direction TB
        CTRL["Controller Manager<br/>(3 replicas)"]

        subgraph WATCHES["Watches & Reconciles"]
            direction LR
            CRD1["SingleInstance<br/>Database"]
            CRD2["Dataguard<br/>Broker"]
            CRD3["Oracle<br/>Restart"]
            CRD4["Rac<br/>Database"]
            CRD5["Sharding<br/>Database"]
            CRD6["Autonomous<br/>Database"]
        end

        CTRL --> WATCHES
    end

    subgraph DEPS["Dependencies"]
        CERT["cert-manager<br/>TLS Certificates"]
        MULTUS["Multus CNI<br/>Multiple Networks"]
    end

    subgraph RBAC["RBAC Permissions"]
        PERMS["Nodes | PVs | StorageClasses<br/>Secrets | ConfigMaps<br/>Pods | Services | StatefulSets"]
    end

    OPERATOR --> DEPS
    OPERATOR --> RBAC

    style OPERATOR fill:#e3f2fd,stroke:#0d47a1
    style DEPS fill:#fff8e1,stroke:#ff6f00
    style RBAC fill:#ffebee,stroke:#c62828
```

### CRD Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Pending: CR Created
    Pending --> Provisioning: Operator picks up
    Provisioning --> Creating: Resources created
    Creating --> Available: Database ready
    Available --> Updating: Spec changed
    Updating --> Available: Update complete
    Available --> Deleting: CR deleted
    Deleting --> [*]: Cleanup complete

    Creating --> Failed: Error
    Failed --> Provisioning: Retry
```

---

## Phase Progression

```mermaid
flowchart LR
    subgraph INFRA["Infrastructure (Phase 0-6)"]
        P0["Phase 0<br/>Windows Prep"]
        P1["Phase 1<br/>Downloads"]
        P2["Phase 2<br/>Golden VM"]
        P3["Phase 3<br/>Clone VMs"]
        P4["Phase 4<br/>Storage"]
        P5["Phase 5<br/>OCNE Install"]
        P6["Phase 6<br/>Operator"]
    end

    subgraph WORKLOADS["Database Workloads"]
        PA["Phase A<br/>SIDB + DG"]
        PB["Phase B<br/>Oracle Restart"]
        PC["Phase C<br/>RAC"]
    end

    P0 --> P1 --> P2 --> P3 --> P4 --> P5 --> P6
    P6 --> PA
    PA --> PB
    PB --> PC

    style P0 fill:#e0e0e0,stroke:#616161
    style P1 fill:#e0e0e0,stroke:#616161
    style P2 fill:#e0e0e0,stroke:#616161
    style P3 fill:#e0e0e0,stroke:#616161
    style P4 fill:#e0e0e0,stroke:#616161
    style P5 fill:#e0e0e0,stroke:#616161
    style P6 fill:#e0e0e0,stroke:#616161
    style PA fill:#c8e6c9,stroke:#2e7d32
    style PB fill:#c8e6c9,stroke:#2e7d32
    style PC fill:#fff8e1,stroke:#ff6f00
```

---

## Summary Table

| Component | Phase A (SIDB+DG) | Phase B (Oracle Restart) | Phase C (RAC) |
|-----------|-------------------|--------------------------|---------------|
| **Namespace** | sidb | rac | rac |
| **CR Type** | SingleInstanceDatabase + DataguardBroker | OracleRestart | RacDatabase |
| **Storage** | NFS (filesystem) | ASM (block devices) | ASM (shared block) |
| **Nodes Used** | ocne-w1 + ocne-w2 | ocne-w1 only | ocne-w1 + ocne-w2 |
| **Database** | 2 instances (primary+standby) | 1 instance (ORCL) | 2 instances (RAC) |
| **HA Mechanism** | Data Guard redo shipping | Oracle Restart auto-restart | RAC + Data Guard |
| **Grid Infra** | None | Yes (19c GI Standalone) | Yes (19c GI Cluster) |
| **ASM** | No | Yes (+DATA diskgroup) | Yes (+DATA, +RECO) |
| **Interconnect** | Flannel (K8s network) | N/A (single node) | Multus macvlan |
| **Status** | Complete | Complete | Planned |
