# Oracle RAC on Kubernetes - Architecture Diagrams

## 1. Complete Infrastructure Architecture

```mermaid
graph TB
    subgraph Windows["Windows Host (VirtualBox)"]
        subgraph VMs["Virtual Machines"]
            subgraph ocne-op["ocne-op (192.168.137.210)"]
                NFS["NFS Server<br/>/export/stage"]
                Operator["OLCNE Operator"]
            end
            subgraph ocne-cp1["ocne-cp1 (192.168.137.211)"]
                API["kube-apiserver"]
                ETCD["etcd"]
                Sched["scheduler"]
                CM["controller-manager"]
            end
            subgraph ocne-w1["ocne-w1 (192.168.137.212)"]
                Pod1["racnode1-0<br/>RAC Node 1"]
            end
            subgraph ocne-w2["ocne-w2 (192.168.137.213)"]
                Pod2["racnode2-0<br/>RAC Node 2"]
            end
        end
        subgraph Networks["VirtualBox Networks"]
            NAT["NAT: 10.0.2.0/24"]
            HostOnly["Host-Only: 192.168.137.0/24"]
            Internal["Internal: 192.168.10.0/24"]
        end
    end

    ocne-op --- HostOnly
    ocne-cp1 --- HostOnly
    ocne-w1 --- HostOnly
    ocne-w2 --- HostOnly
    ocne-w1 --- Internal
    ocne-w2 --- Internal
```

---

## 2. Kubernetes Layer Architecture

```mermaid
graph TB
    subgraph K8s["Kubernetes Cluster (OCNE 1.9)"]
        subgraph CP["Control Plane (ocne-cp1)"]
            API2["kube-apiserver"]
            ETCD2["etcd"]
            Sched2["scheduler"]
            CM2["controller-manager"]
            DBOp["Oracle Database<br/>Operator"]
        end

        subgraph NS["Namespace: rac"]
            subgraph W1["Worker: ocne-w1<br/>Label: raccluster=raccluster01"]
                subgraph P1["Pod: racnode1-0"]
                    C1["Container: racnode1-0<br/>Grid Infrastructure<br/>Oracle Database 19c<br/>ASM: +ASM1<br/>Instance: RACDB1<br/>IP: 10.244.1.222"]
                end
            end
            subgraph W2["Worker: ocne-w2<br/>Label: raccluster=raccluster01"]
                subgraph P2["Pod: racnode2-0"]
                    C2["Container: racnode2-0<br/>Grid Infrastructure<br/>Oracle Database 19c<br/>ASM: +ASM2<br/>Instance: RACDB2<br/>IP: 10.244.2.53"]
                end
            end
            subgraph Services["Kubernetes Services"]
                SCAN["racnode-scan<br/>Port: 31521"]
                SVC1["racnode1-0-svc<br/>Port: 31522"]
                SVC2["racnode2-0-svc<br/>Port: 31522"]
                ONS["ONS Services<br/>Port: 30200"]
            end
            subgraph Secrets["Secrets"]
                SSH["ssh-key-secret"]
                DBPW["db-user-pass-pkutl"]
                REG["oracle-container-<br/>registry-secret"]
            end
        end
    end

    DBOp --> P1
    DBOp --> P2
    SCAN --> P1
    SCAN --> P2
```

---

## 3. Network Architecture

```mermaid
graph TB
    subgraph Public["Public Network (Pod Network) - 10.244.0.0/16"]
        subgraph PN1["racnode1-0"]
            ETH1["eth0: 10.244.1.222<br/>VIP: 10.244.1.x"]
        end
        subgraph PN2["racnode2-0"]
            ETH2["eth0: 10.244.2.53<br/>VIP: 10.244.2.x"]
        end
        SCANVIP["SCAN Listeners<br/>racnode-scan:1521"]
    end

    ETH1 <-->|Calico CNI| ETH2
    ETH1 --> SCANVIP
    ETH2 --> SCANVIP

    subgraph Private1["Private Interconnect 1 (Macvlan) - 192.168.10.0/24"]
        subgraph PI1["racnode1-0"]
            ENS1A["ens1: 192.168.10.x"]
        end
        subgraph PI2["racnode2-0"]
            ENS1B["ens1: 192.168.10.x"]
        end
        ICT["Oracle Cluster<br/>Interconnect Traffic<br/>(Cache Fusion, GCS)"]
    end

    ENS1A <-->|Macvlan enp0s8| ENS1B

    subgraph Private2["Private Interconnect 2 (Macvlan) - 192.168.11.0/24"]
        subgraph PI3["racnode1-0"]
            ENS2A["ens2: 192.168.11.x"]
        end
        subgraph PI4["racnode2-0"]
            ENS2B["ens2: 192.168.11.x"]
        end
        RED["Redundant Interconnect<br/>for HA"]
    end

    ENS2A <-->|Macvlan enp0s9| ENS2B
```

---

## 4. Storage Architecture

```mermaid
graph TB
    subgraph NFS["NFS Storage (ocne-op)"]
        EXPORT["/export/stage/"]
        GI["LINUX.X64_193000_grid_home.zip<br/>(2.7 GB)"]
        DB["LINUX.X64_193000_db_home.zip<br/>(2.9 GB)"]
        OP["p6880880_190000_Linux-x86-64.zip"]
        RU["19c/19.29/RU/39467003<br/>Release Update Patches"]
    end

    subgraph Pods["RAC Pods Mount Points"]
        MNT1["/mnt/stage/software"]
        MNT2["/mnt/stage/opatch"]
        MNT3["/mnt/stage/rupatch"]
    end

    EXPORT --> MNT1
    EXPORT --> MNT2
    EXPORT --> MNT3

    subgraph Local["Local Storage (Worker Nodes)"]
        subgraph LW1["ocne-w1"]
            SDA1["/dev/sda (60GB) - OS"]
            SDB1["/dev/sdb (50GB) - LVM<br/>/u01 (vg_data)<br/>Grid Home, DB Home"]
        end
        subgraph LW2["ocne-w2"]
            SDA2["/dev/sda (60GB) - OS"]
            SDB2["/dev/sdb (50GB) - LVM<br/>/u01 (vg_data)<br/>Grid Home, DB Home"]
        end
    end

    subgraph ASM["Shared ASM Storage (VirtualBox Shareable)"]
        subgraph DG["+DATA Disk Group<br/>Redundancy: EXTERNAL"]
            SDC["/dev/sdc (20GB)<br/>asmdisk0001"]
            SDD["/dev/sdd (20GB)<br/>asmdisk0002"]
        end
        ASM1["+ASM1<br/>(ocne-w1)"]
        ASM2["+ASM2<br/>(ocne-w2)"]
    end

    ASM1 <--> SDC
    ASM1 <--> SDD
    ASM2 <--> SDC
    ASM2 <--> SDD
```

---

## 5. ASM Disk Group Contents

```mermaid
graph LR
    subgraph DATA["+DATA Disk Group"]
        subgraph RACDB["RACDB/"]
            CF["CONTROLFILE/<br/>current.263"]
            DF["DATAFILE/<br/>system, sysaux,<br/>undotbs1, undotbs2,<br/>users"]
            OL["ONLINELOG/<br/>group_1, group_2,<br/>group_3, group_4"]
            TF["TEMPFILE/<br/>temp01.dbf"]
            PF["PARAMETERFILE/<br/>spfile"]
            PW["PASSWORD/<br/>pwdracdb"]
        end
    end
```

---

## 6. Oracle RAC Component Architecture

```mermaid
graph TB
    subgraph Clients["Client Connections"]
        APP["Client App<br/>(SQL*Plus, JDBC)"]
    end

    APP --> SCAN

    subgraph SCAN["SCAN Service"]
        SCANVIP2["SCAN VIP<br/>racnode-scan:1521/31521"]
    end

    SCANVIP2 --> SL1
    SCANVIP2 --> SL2

    subgraph ScanListeners["SCAN Listeners"]
        SL1["SCAN_LISTENER_1<br/>(racnode1-0)"]
        SL2["SCAN_LISTENER_2<br/>(racnode2-0)"]
    end

    SL1 --> RACDB1
    SL2 --> RACDB2

    subgraph Database["Database: RACDB"]
        subgraph RACDB1["Instance: RACDB1 (racnode1-0)"]
            SGA1["SGA (8GB)<br/>Buffer Cache<br/>Shared Pool<br/>Large Pool"]
            PGA1["PGA (2GB)"]
            BG1["Background Processes<br/>PMON, SMON, DBW0<br/>LGWR, LMS0, LMD0"]
            LL1["Local Listener: 1521<br/>VIP: racnode1-0-vip"]
        end
        subgraph RACDB2["Instance: RACDB2 (racnode2-0)"]
            SGA2["SGA (8GB)<br/>Buffer Cache<br/>Shared Pool<br/>Large Pool"]
            PGA2["PGA (2GB)"]
            BG2["Background Processes<br/>PMON, SMON, DBW0<br/>LGWR, LMS0, LMD0"]
            LL2["Local Listener: 1521<br/>VIP: racnode2-0-vip"]
        end

        UNDO["UNDO Tablespaces<br/>UNDOTBS1 (RACDB1)<br/>UNDOTBS2 (RACDB2)"]

        subgraph PDB["PDB: ORCLPDB"]
            PDBTBS["SYSTEM TS | SYSAUX TS | USERS TS<br/>Service: racpdb"]
        end
    end

    SGA1 <-->|"Cache Fusion<br/>GCS/GES"| SGA2

    RACDB1 --> ASMDATA
    RACDB2 --> ASMDATA

    subgraph ASMDATA["+DATA (ASM)"]
        ASMFILES["Datafiles | Controlfile<br/>Redo Logs | Temp Files"]
    end
```

---

## 7. Grid Infrastructure Stack

```mermaid
graph TB
    subgraph CW["Oracle Clusterware Stack"]
        CRSD["CRSD<br/>Cluster Ready Services Daemon<br/>Manages cluster resources<br/>High availability operations"]

        CRSD --> EVMD
        CRSD --> OCSSD
        CRSD --> CSSD

        EVMD["EVMD<br/>Event Manager Daemon"]
        OCSSD["OCSSD<br/>Cluster Sync Services"]
        CSSD["CSSD<br/>Cluster Sync Services"]

        OCSSD --> OHASD

        OHASD["OHASD<br/>Oracle High Availability Services Daemon<br/>Starts Oracle Clusterware<br/>First process started"]

        OHASD --> OS

        OS["Operating System<br/>Oracle Linux 9.8 with UEK"]
    end

    subgraph Resources["CRS Resources"]
        subgraph Local["Local Resources (per node)"]
            LR1["ora.DBLSNR.lsnr"]
            LR2["ora.LISTENER.lsnr"]
            LR3["ora.chad"]
            LR4["ora.net1.network"]
            LR5["ora.ons"]
        end
        subgraph Cluster["Cluster Resources"]
            CR1["ora.LISTENER_SCAN1.lsnr"]
            CR2["ora.LISTENER_SCAN2.lsnr"]
            CR3["ora.racdb.db"]
            CR4["ora.racdb.racpdb.svc"]
            CR5["ora.racnode1-0.vip"]
            CR6["ora.racnode2-0.vip"]
            CR7["ora.DATA.dg"]
            CR8["ora.asm"]
        end
    end
```

---

## 8. Data Flow Diagram

```mermaid
flowchart TB
    Client["Client App<br/>(SQL*Plus, JDBC)"]

    Client -->|"Connect to SCAN<br/>racnode-scan:1521/ORCLPDB"| SCANVIP

    SCANVIP["SCAN VIP / DNS<br/>(Kubernetes Service)"]

    SCANVIP --> SL1
    SCANVIP --> SL2
    SCANVIP --> SL3

    SL1["SCAN Listener 1<br/>(racnode1-0)"]
    SL2["SCAN Listener 2<br/>(racnode2-0)"]
    SL3["SCAN Listener 3<br/>(if 3 nodes)"]

    SL1 -->|"Server-side<br/>Load Balancing"| LL1
    SL2 -->|"Server-side<br/>Load Balancing"| LL2

    LL1["Local Listener<br/>racnode1-0:1521"]
    LL2["Local Listener<br/>racnode2-0:1521"]

    LL1 --> SP1
    LL2 --> SP2

    subgraph RACDB1["RACDB1"]
        SP1["Server Process<br/>(Dedicated)"]
        BC1["Buffer Cache<br/>(SGA)"]
        SP1 --> BC1
    end

    subgraph RACDB2["RACDB2"]
        SP2["Server Process<br/>(Dedicated)"]
        BC2["Buffer Cache<br/>(SGA)"]
        SP2 --> BC2
    end

    BC1 <-->|"Cache Fusion<br/>(GCS/GES)"| BC2

    BC1 --> ASM
    BC2 --> ASM

    subgraph ASM["+DATA (ASM)"]
        Files["Datafiles<br/>Controlfile<br/>Redo Logs<br/>Temp Files"]
    end
```

---

## 9. High Availability - Failure Scenarios

### Scenario 1: Instance Failure

```mermaid
flowchart LR
    subgraph Before["Before Failure"]
        R1A["RACDB1<br/>ONLINE"]
        R2A["RACDB2<br/>ONLINE"]
    end

    subgraph After["After Failure"]
        R1B["RACDB1<br/>DOWN"]
        R2B["RACDB2<br/>ONLINE"]
    end

    R1A -->|"Instance Fails"| R1B
    R2A --> R2B

    R1B -.->|"VIP Failover<br/>SCAN Redirects<br/>Instance Recovery"| R2B
```

### Scenario 2: Node Failure

```mermaid
flowchart LR
    subgraph Before2["Before Failure"]
        N1A["racnode1-0<br/>+ASM1, RACDB1<br/>ONLINE"]
        N2A["racnode2-0<br/>+ASM2, RACDB2<br/>ONLINE"]
    end

    subgraph After2["After Failure"]
        N1B["racnode1-0<br/>DOWN"]
        N2B["racnode2-0<br/>+ASM2, RACDB2<br/>ONLINE"]
    end

    N1A -->|"Node Fails<br/>(Hardware/OS)"| N1B
    N2A --> N2B

    N1B -.->|"CSS Detects<br/>Node Evicted<br/>Services Relocated"| N2B
```

### Scenario 3: Split Brain Prevention

```mermaid
flowchart TB
    subgraph Partition["Network Partition"]
        N1["racnode1-0"]
        N2["racnode2-0"]
    end

    N1 <-->|"Interconnect<br/>FAILS"| N2

    N1 -->|"Race to<br/>Access"| VD
    N2 -->|"Race to<br/>Access"| VD

    VD["Voting Disk<br/>(in +DATA)"]

    VD -->|"Winner Stays"| Winner["Surviving Node"]
    VD -->|"Loser Fenced"| Loser["Evicted Node"]
```

---

## 10. HA Components Summary

```mermaid
graph LR
    subgraph Components["High Availability Components"]
        DB["Database Instances<br/>2x (RACDB1, RACDB2)<br/>Failover: <30 sec"]
        ASM["ASM Instances<br/>2x (+ASM1, +ASM2)<br/>Failover: Automatic"]
        SCAN2["SCAN Listeners<br/>2x (across nodes)<br/>Failover: Automatic"]
        VIP["VIPs<br/>2x (per node)<br/>Failover: <30 sec"]
        ICT2["Private Interconnect<br/>2x (ens1, ens2)<br/>Failover: Automatic"]
        DG2["ASM Disk Group<br/>EXTERNAL (no mirror)<br/>Single Point of Failure"]
    end
```

---

## 11. Deployment Flow

```mermaid
flowchart TB
    subgraph Phase1["Phase 1: Pod Creation"]
        Apply["kubectl apply -f racdb.yaml"]
        Operator["Oracle Database Operator"]
        Pods["Create Pods<br/>racnode1-0, racnode2-0<br/>Mount NFS, Attach Macvlan"]

        Apply --> Operator --> Pods
    end

    subgraph Phase2["Phase 2: Grid Infrastructure"]
        Extract1["Extract Software<br/>from NFS"]
        OPatch["Update OPatch"]
        GridSetup["Run gridSetup.sh"]
        ApplyRU["Apply RU Patches"]
        RootSh1["Execute root.sh<br/>(both nodes)"]

        Extract1 --> OPatch --> GridSetup --> ApplyRU --> RootSh1
    end

    subgraph Phase3["Phase 3: Database Software"]
        Extract2["Extract DB Home"]
        RunInst["Run runInstaller<br/>(-noCopy)"]
        OpatchDB["Apply opatchauto"]
        RootSh2["Run root.sh<br/>(DB home)"]

        Extract2 --> RunInst --> OpatchDB --> RootSh2
    end

    subgraph Phase4["Phase 4: Database Creation"]
        CreateDB["Create Database<br/>(RACDB)"]
        StartInst["Start Instances<br/>(RACDB1, RACDB2)"]
        Catalog["Run Catalog Scripts"]
        CreatePDB["Create PDB<br/>(ORCLPDB)"]
        Datapatch["Apply datapatch"]

        CreateDB --> StartInst --> Catalog --> CreatePDB --> Datapatch
    end

    subgraph Phase5["Phase 5: Post-Config"]
        RegSvc["Register Services<br/>with CRS"]
        ConfLsnr["Configure Listeners"]
        StartAll["Start All Services"]
        Complete["DEPLOYMENT<br/>COMPLETE!"]

        RegSvc --> ConfLsnr --> StartAll --> Complete
    end

    Pods --> Extract1
    RootSh1 --> Extract2
    RootSh2 --> CreateDB
    Datapatch --> RegSvc
```

---

## 12. Quick Reference

| Category | Item | Value |
|----------|------|-------|
| **Hostnames** | racnode1-0 | 10.244.1.222 (Pod IP) |
| | racnode2-0 | 10.244.2.53 (Pod IP) |
| | racnode-scan | Kubernetes Service (SCAN) |
| **Ports** | Local Listener (pod) | 1521 |
| | SCAN Listener (NodePort) | 31521 |
| | Local Listener (NodePort) | 31522 |
| | ONS (NodePort) | 30200 |
| **Oracle Homes** | GRID_HOME | /u01/app/19c/grid |
| | GRID_BASE | /u01/app/grid |
| | ORACLE_HOME | /u01/app/oracle/product/19c/dbhome_1 |
| | ORACLE_BASE | /u01/app/oracle |
| **Users** | grid | Grid Infrastructure owner (uid 54321) |
| | oracle | Database owner (uid 54321) |
| **Connect Strings** | CDB | `sqlplus sys/oracle@racnode-scan:1521/RACDB as sysdba` |
| | PDB | `sqlplus sys/oracle@racnode-scan:1521/ORCLPDB as sysdba` |

### Common Commands

```bash
# Check cluster status
crsctl check cluster -all

# Check all CRS resources
crsctl status res -t

# Check database status
srvctl status database -d RACDB

# Check ASM status
srvctl status asm

# List ASM disk groups
asmcmd lsdg

# Check listener status
lsnrctl status
```

---

*Document Version: 2.0 (Mermaid)*
*Created: September 2026*
