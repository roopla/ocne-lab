# Oracle RAC Deployment - Command Output Proof

## Deployment Verification Evidence

**Capture Date:** September 27, 2026
**Cluster:** OCNE 1.9 Kubernetes with Oracle Database Operator v4

---

## 1. Kubernetes Resources

### 1.1 RAC Pods Status

```bash
$ kubectl get pods -n rac -o wide
```
```
NAME         READY   STATUS    RESTARTS   AGE    IP             NODE                NOMINATED NODE   READINESS GATES
racnode1-0   1/1     Running   0          6h6m   10.244.1.222   ocne-w1.lab.local   <none>           <none>
racnode2-0   1/1     Running   0          6h6m   10.244.2.53    ocne-w2.lab.local   <none>           <none>
```

### 1.2 RAC Services

```bash
$ kubectl get svc -n rac
```
```
NAME                TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)           AGE
racnode-scan        ClusterIP   None             <none>        <none>            9h
racnode-scan-lsnr   NodePort    10.97.24.47      <none>        1521:31521/TCP    9h
racnode1-0          ClusterIP   None             <none>        <none>            9h
racnode1-0-lsnr     NodePort    10.98.146.12     <none>        31522:31522/TCP   9h
racnode1-0-ons      NodePort    10.107.209.172   <none>        6200:30200/TCP    9h
racnode1-0-vip      ClusterIP   None             <none>        <none>            9h
racnode2-0          ClusterIP   None             <none>        <none>            9h
racnode2-0-lsnr     NodePort    10.108.21.186    <none>        31523:31523/TCP   9h
racnode2-0-ons      NodePort    10.108.204.174   <none>        6200:30201/TCP    9h
racnode2-0-vip      ClusterIP   None             <none>        <none>            9h
```

### 1.3 RacDatabase Custom Resource

```bash
$ kubectl get racdatabase -n rac -o wide
```
```
NAME      DBNAME   DBSTATE   ROLE      VERSION       PDB CONNECT STR            STATE
racdb01   RACDB    OPEN      PRIMARY   19.32.0.0.0   racnode-scan:1521/racpdb   AVAILABLE
```

### 1.4 Secrets

```bash
$ kubectl get secrets -n rac
```
```
NAME                               TYPE                             DATA   AGE
db-user-pass-pkutl                 Opaque                           2      36h
oracle-container-registry-secret   kubernetes.io/dockerconfigjson   1      12h
ssh-key-secret                     Opaque                           2      36h
```

### 1.5 Network Attachment Definitions

```bash
$ kubectl get net-attach-def -n rac
```
```
NAME        AGE
rac-priv1   9h
rac-priv2   9h
```

### 1.6 Cluster Nodes

```bash
$ kubectl get nodes -o wide
```
```
NAME                 STATUS   ROLES           AGE    VERSION          INTERNAL-IP       EXTERNAL-IP   OS-IMAGE                  KERNEL-VERSION                     CONTAINER-RUNTIME
ocne-cp1.lab.local   Ready    control-plane   7d3h   v1.29.14+2.el9   192.168.137.211   <none>        Oracle Linux Server 9.8   5.15.0-324.217.5.3.el9uek.x86_64   cri-o://1.29.1
ocne-w1.lab.local    Ready    worker          7d3h   v1.29.14+2.el9   192.168.137.221   <none>        Oracle Linux Server 9.8   5.15.0-324.217.5.3.el9uek.x86_64   cri-o://1.29.1
ocne-w2.lab.local    Ready    worker          7d3h   v1.29.14+2.el9   192.168.137.222   <none>        Oracle Linux Server 9.8   5.15.0-324.217.5.3.el9uek.x86_64   cri-o://1.29.1
```

### 1.7 RacDatabase Detailed Description (Partial)

```bash
$ kubectl describe racdatabase racdb01 -n rac
```
```
Name:         racdb01
Namespace:    rac
Labels:       <none>
API Version:  database.oracle.com/v4
Kind:         RacDatabase
Metadata:
  Creation Timestamp:  2026-09-26T15:10:44Z
  Finalizers:
    database.oracle.com/racdatabasefinalizer
  Generation:        3
  Resource Version:  342485
  UID:               2c6fac51-e89d-4c7a-b162-21d448ce8432
Spec:
  Asm Disk Group Details:
    Disks:
      /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001
      /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002
    Name:        DATA
    Redundancy:  EXTERNAL
    Type:        CRSDG
  Config Params:
    Cpu Count:               4
    Db Base:                 /u01/app/oracle
    Db Char Set:             AL32UTF8
    Db Home:                 /u01/app/oracle/product/19c/dbhome_1
    Db Name:                 RACDB
    Db Sw Zip File:          LINUX.X64_193000_db_home.zip
    Grid Base:               /u01/app/grid
    Grid Home:               /u01/app/19c/grid
    Grid Sw Zip File:        LINUX.X64_193000_grid_home.zip
    Host Sw Stage Location:  /scratch/software/stage
    Inventory:               /u01/app/oraInventory
    O Patch Location:        /scratch/software/stage/19c/19.29/OPATCH
    O Patch Sw Zip File:     p6880880_190000_Linux-x86-64.zip
    Pdb Name:                RACPDB
    Pga Size:                2G
    Processes:               1000
    Ru Patch Location:       /scratch/software/stage/19c/19.29/RU/39467003
    Sga Size:                8G
    Sw Mount Location:       /u01
  Db Secret:
    Encryption Type:          pkeyutl
    Key File Mount Location:  /mnt/.dbsecrets
    Key File Name:            key.pem
    Name:                     db-user-pass-pkutl
    Pkeyopt:                  rsa_padding_mode:oaep;rsa_oaep_md:sha256;rsa_mgf1_md:sha256
    Pwd File Mount Location:  /mnt/.dbsecrets
    Pwd File Name:            pwdfile.enc
  Env Vars:
    Name:             LOG_DIR
    Value:            /tmp/orod
    Name:             IGNORE_CRS_PREREQS
    Value:            true
    Name:             IGNORE_DB_PREREQS
    Value:            true
  Image:              container-registry.oracle.com/database/rac_ru:latest-19
  Image Pull Policy:  IfNotPresent
  Image Pull Secret:  oracle-container-registry-secret
  Instance Details:
    Base Lsnr Target Port:  31522
    Base Ons Target Port:   30200
    Node Count:             2
    Private IP Details:
      Interface:           ens1
      Name:                rac-priv1
      Interface:           ens2
      Name:                rac-priv2
    Rac Host Sw Location:  /scratch/rac/cluster01
    Rac Node Name:         racnode
    Worker Node Selector:
      Raccluster:  raccluster01
  Resources:
    Limits:
      Cpu:     6
      Memory:  18Gi
    Requests:
      Cpu:               4
      Memory:            16Gi
```

---

## 2. Oracle Clusterware Status

### 2.1 Cluster Status (All Nodes)

```bash
$ crsctl check cluster -all
```
```
**************************************************************
racnode1-0:
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
**************************************************************
racnode2-0:
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
**************************************************************
```

### 2.2 CRS Resources Status

```bash
$ crsctl status res -t
```
```
--------------------------------------------------------------------------------
Name           Target  State        Server                   State details
--------------------------------------------------------------------------------
Local Resources
--------------------------------------------------------------------------------
ora.DBLSNR.lsnr
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
ora.LISTENER.lsnr
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
ora.chad
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
ora.net1.network
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
ora.ons
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
--------------------------------------------------------------------------------
Cluster Resources
--------------------------------------------------------------------------------
ora.ASMNET1LSNR_ASM.lsnr(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.ASMNET2LSNR_ASM.lsnr(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.DATA.dg(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.LISTENER_SCAN1.lsnr
      1        ONLINE  ONLINE       racnode1-0               STABLE
ora.LISTENER_SCAN2.lsnr
      1        ONLINE  ONLINE       racnode2-0               STABLE
ora.asm(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               Started,STABLE
      2        ONLINE  ONLINE       racnode2-0               Started,STABLE
ora.asmnet1.asmnetwork(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.asmnet2.asmnetwork(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.cvu
      1        ONLINE  ONLINE       racnode1-0               STABLE
ora.racdb.db
      1        ONLINE  ONLINE       racnode1-0               Open,HOME=/u01/app/o
                                                             racle/product/19c/db
                                                             home_1,STABLE
      2        ONLINE  ONLINE       racnode2-0               Open,HOME=/u01/app/o
                                                             racle/product/19c/db
                                                             home_1,STABLE
ora.racdb.racpdb.svc
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.racnode1-0.vip
      1        ONLINE  ONLINE       racnode1-0               STABLE
ora.racnode2-0.vip
      1        ONLINE  ONLINE       racnode2-0               STABLE
ora.scan1.vip
      1        ONLINE  ONLINE       racnode1-0               STABLE
ora.scan2.vip
      1        ONLINE  ONLINE       racnode2-0               STABLE
--------------------------------------------------------------------------------
```

### 2.3 Cluster Nodes

```bash
$ olsnodes -n -i -s -t
```
```
racnode1-0	1	<none>	Active	Unpinned
racnode2-0	2	<none>	Active	Unpinned
```

### 2.4 OCR Check

```bash
$ ocrcheck
```
```
Status of Oracle Cluster Registry is as follows :
	 Version                  :          4
	 Total space (kbytes)     :     901284
	 Used space (kbytes)      :      84284
	 Available space (kbytes) :     817000
	 ID                       :   90342285
	 Device/File Name         :      +DATA
                                    Device/File integrity check succeeded

                                    Device/File not configured

                                    Device/File not configured

                                    Device/File not configured

                                    Device/File not configured

	 Cluster registry integrity check succeeded

	 Logical corruption check bypassed due to non-privileged user
```

---

## 3. Database Status

### 3.1 Database Status (Verbose)

```bash
$ srvctl status database -d RACDB -v
```
```
Instance RACDB1 is running on node racnode1-0 with online services racpdb. Instance status: Open.
Instance RACDB2 is running on node racnode2-0 with online services racpdb. Instance status: Open.
```

### 3.2 Database Configuration

```bash
$ srvctl config database -d RACDB
```
```
Database unique name: RACDB
Database name: RACDB
Oracle home: /u01/app/oracle/product/19c/dbhome_1
Oracle user: oracle
Spfile: +DATA/RACDB/PARAMETERFILE/spfile.277.1245024969
Password file: +DATA/RACDB/PASSWORD/pwdracdb.258.1245022833
Domain:
Start options: open
Stop options: immediate
Database role: PRIMARY
Management policy: AUTOMATIC
Server pools:
Disk Groups: DATA
Mount point paths:
Services: racpdb
Type: RAC
Start concurrency:
Stop concurrency:
OSDBA group: dba
OSOPER group:
Database instances: RACDB1,RACDB2
Configured nodes: racnode1-0,racnode2-0
CSS critical: no
CPU count: 0
Memory target: 0
Maximum memory: 0
Default network number for database services:
Database is administrator managed
```

### 3.3 PDB Status

```bash
SQL> show pdbs
```
```
    CON_ID CON_NAME			  OPEN MODE  RESTRICTED
---------- ------------------------------ ---------- ----------
	 2 PDB$SEED			  READ ONLY  NO
	 3 ORCLPDB			  READ WRITE NO
```

---

## 4. ASM Status

### 4.1 ASM Instance Status

```bash
$ srvctl status asm
```
```
ASM is running on racnode1-0,racnode2-0
```

### 4.2 ASM Disk Groups

```bash
$ asmcmd lsdg
```
```
State    Type    Rebal  Sector  Logical_Sector  Block       AU  Total_MB  Free_MB  Req_mir_free_MB  Usable_file_MB  Offline_disks  Voting_files  Name
MOUNTED  EXTERN  N         512             512   4096  4194304     81920    70604                0           70604              0             Y  DATA/
```

### 4.3 ASM Disks

```bash
$ asmcmd lsdsk -k
```
```
Total_MB  Free_MB  OS_MB  Name       Failgroup  Site_Name  Site_GUID                         Site_Status  Failgroup_Type  Library  Label  Failgroup_Label  Site_Label  UDID  Product  Redund   Path
   40960    35312  40960  DATA_0000  DATA_0000             00000000000000000000000000000000               REGULAR         System                                                      UNKNOWN  /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001
   40960    35292  40960  DATA_0001  DATA_0001             00000000000000000000000000000000               REGULAR         System                                                      UNKNOWN  /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002
```

---

## 5. Listener Status

### 5.1 Local Listener Status

```bash
$ lsnrctl status
```
```
LSNRCTL for Linux: Version 19.0.0.0.0 - Production on 27-SEP-2026 00:40:49

Copyright (c) 1991, 2026, Oracle.  All rights reserved.

Connecting to (DESCRIPTION=(ADDRESS=(PROTOCOL=IPC)(KEY=LISTENER)))
STATUS of the LISTENER
------------------------
Alias                     LISTENER
Version                   TNSLSNR for Linux: Version 19.0.0.0.0 - Production
Start Date                26-SEP-2026 19:42:15
Uptime                    0 days 4 hr. 58 min. 34 sec
Trace Level               off
Security                  ON: Local OS Authentication
SNMP                      OFF
Listener Parameter File   /u01/app/19c/grid/network/admin/listener.ora
Listener Log File         /u01/app/grid/diag/tnslsnr/racnode1-0/listener/alert/log.xml
Listening Endpoints Summary...
  (DESCRIPTION=(ADDRESS=(PROTOCOL=ipc)(KEY=LISTENER)))
  (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=10.244.1.222)(PORT=1522)))
Services Summary...
Service "+ASM" has 1 instance(s).
  Instance "+ASM1", status READY, has 1 handler(s) for this service...
Service "+ASM_DATA" has 1 instance(s).
  Instance "+ASM1", status READY, has 1 handler(s) for this service...
The command completed successfully
```

### 5.2 SCAN Listener Status

```bash
$ srvctl status scan_listener
```
```
SCAN Listener LISTENER_SCAN1 is enabled
SCAN listener LISTENER_SCAN1 is running on node racnode1-0
SCAN Listener LISTENER_SCAN2 is enabled
SCAN listener LISTENER_SCAN2 is running on node racnode2-0
```

---

## 6. Patch Status

### 6.1 Grid Infrastructure Patches

```bash
$ $GRID_HOME/OPatch/opatch lspatches
```
```
39526364;OCW RELEASE UPDATE 19.32.0.0.0 (39526364)
39503034;ACFS RELEASE UPDATE 19.32.0.0.0 (39503034)
39472050;Database Release Update : 19.32.0.0.260721 (39472050)
39107855;TOMCAT RELEASE UPDATE 19.0.0.0.0 (39107855)
39107825;DBWLM RELEASE UPDATE 19.0.0.0.0 (39107825)

OPatch succeeded.
```

### 6.2 Database Home Patches

```bash
$ $ORACLE_HOME/OPatch/opatch lspatches
```
```
39526364;OCW RELEASE UPDATE 19.32.0.0.0 (39526364)
39472050;Database Release Update : 19.32.0.0.260721 (39472050)

OPatch succeeded.
```

---

## 7. Oracle Inventory

```bash
$ cat /u01/app/oraInventory/ContentsXML/inventory.xml
```
```xml
<?xml version="1.0" standalone="yes" ?>
<!-- Copyright (c) 1999, 2026, Oracle and/or its affiliates.
All rights reserved. -->
<!-- Do not modify the contents of this file by hand. -->
<INVENTORY>
<VERSION_INFO>
   <SAVED_WITH>12.2.0.7.0</SAVED_WITH>
   <MINIMUM_VER>2.1.0.6.0</MINIMUM_VER>
</VERSION_INFO>
<HOME_LIST>
<HOME NAME="OraGI19Home1" LOC="/u01/app/19c/grid" TYPE="O" IDX="1" CRS="true"/>
<HOME NAME="OraDB19Home1" LOC="/u01/app/oracle/product/19c/dbhome_1" TYPE="O" IDX="2"/>
</HOME_LIST>
<COMPOSITEHOME_LIST>
</COMPOSITEHOME_LIST>
</INVENTORY>
```

---

## 8. Filesystem and Storage

### 8.1 Filesystem Usage (racnode1-0)

```bash
$ df -h
```
```
Filesystem                                   Size  Used Avail Use% Mounted on
overlay                                       60G   47G   14G  78% /
tmpfs                                         64M     0   64M   0% /dev
tmpfs                                        3.9G  136M  3.7G   4% /etc/hostname
tmpfs                                        9.6G  132K  9.6G   1% /run
/dev/mapper/vg_data-lv_scratch                50G   30G   20G  61% /u01
tmpfs                                         18G  8.0K   18G   1% /mnt/.ssh
tmpfs                                         18G  8.0K   18G   1% /mnt/.dbsecrets
tmpfs                                         18G  1.4G   16G   8% /dev/shm
/dev/sda2                                     38G  9.5G   29G  25% /etc/hosts
ocne-op:/export/stage                        150G   18G  133G  12% /mnt/stage/software
ocne-op:/export/stage/19c/19.29/OPATCH       150G   18G  133G  12% /mnt/stage/opatch
ocne-op:/export/stage/19c/19.29/RU/39467003  150G   18G  133G  12% /mnt/stage/rupatch
tmpfs                                        9.6G     0  9.6G   0% /run/lock
tmpfs                                        9.6G  3.0M  9.6G   1% /tmp
tmpfs                                        9.6G   32M  9.6G   1% /var/log/journal
tmpfs                                        9.6G     0  9.6G   0% /proc/asound
tmpfs                                        9.6G     0  9.6G   0% /proc/acpi
tmpfs                                        9.6G     0  9.6G   0% /proc/scsi
tmpfs                                        9.6G     0  9.6G   0% /sys/firmware
```

---

## 9. Network Configuration

### 9.1 Hosts File (racnode1-0)

```bash
$ cat /etc/hosts
```
```
# Kubernetes-managed hosts file.
127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
fe00::0	ip6-localnet
fe00::0	ip6-mcastprefix
fe00::1	ip6-allnodes
fe00::2	ip6-allrouters
10.244.1.222	racnode1-0.racnode.rac.svc.cluster.local	racnode1-0
10.244.2.53 racnode2-0.rac.svc.cluster.local racnode2-0-vip
10.244.1.222 racnode1-0.rac.svc.cluster.local racnode1-0-vip
```

---

## 10. Setup Completion Status

### 10.1 Setup Statefile

```bash
$ cat /tmp/orod/.statefile
```
```
completed
```

---

## Summary

| Check | Status |
|-------|--------|
| Kubernetes Pods | ✅ 2/2 Running |
| Kubernetes Services | ✅ 10 Services Created |
| RacDatabase CR | ✅ AVAILABLE, OPEN, PRIMARY |
| CRS Cluster | ✅ Online on both nodes |
| CRS Resources | ✅ All ONLINE/STABLE |
| Database Instances | ✅ RACDB1, RACDB2 Open |
| PDB | ✅ ORCLPDB READ WRITE |
| ASM | ✅ Running on both nodes |
| ASM Disk Group | ✅ DATA MOUNTED (81GB, 70GB free) |
| SCAN Listeners | ✅ Running on both nodes |
| Grid Patches | ✅ 19.32.0.0.0 RU Applied |
| DB Patches | ✅ 19.32.0.0.0 RU Applied |
| Setup State | ✅ completed |

---

---

## 11. Database Login and SQL Queries

### 11.1 Login as SYSDBA

```bash
$ kubectl exec racnode1-0 -n rac -- su - oracle -c 'sqlplus / as sysdba'

SQL*Plus: Release 19.0.0.0.0 - Production on Sat Sep 27 00:55:00 2026
Version 19.32.0.0.0

Copyright (c) 1982, 2026, Oracle.  All rights reserved.

Connected to:
Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production
Version 19.32.0.0.0

SQL> SHOW USER
USER is "SYS"
```

### 11.2 Local Instance Information (v$instance)

```sql
SQL> SELECT instance_name, host_name, status, database_status FROM v$instance;

INSTANCE_NAME   HOST_NAME                      STATUS       DATABASE_STATUS
--------------- ------------------------------ ------------ -----------------
RACDB1          racnode1-0                     OPEN         ACTIVE
```

### 11.3 All RAC Instances (gv$instance)

```sql
SQL> SELECT inst_id, instance_name, host_name, status FROM gv$instance ORDER BY inst_id;

   INST_ID INSTANCE_NAME   HOST_NAME                      STATUS
---------- --------------- ------------------------------ ------------
         1 RACDB1          racnode1-0                     OPEN
         2 RACDB2          racnode2-0                     OPEN
```

### 11.4 Database Information (v$database)

```sql
SQL> SELECT name, open_mode, database_role, log_mode FROM v$database;

NAME         OPEN_MODE       DATABASE_ROLE        LOG_MODE
------------ --------------- -------------------- ---------------
RACDB        READ WRITE      PRIMARY              ARCHIVELOG
```

### 11.5 Pluggable Databases (v$pdbs)

```sql
SQL> SELECT con_id, name, open_mode FROM v$pdbs ORDER BY con_id;

    CON_ID NAME                 OPEN_MODE
---------- -------------------- ----------
         2 PDB$SEED             READ ONLY
         3 ORCLPDB              READ WRITE
```

### 11.6 Datafiles (v$datafile)

```sql
SQL> SELECT file#, status, name AS file_name FROM v$datafile;

     FILE# STATUS       FILE_NAME
---------- ------------ ------------------------------------------------------------
         1 SYSTEM       +DATA/RACDB/DATAFILE/system.259.1245022877
         3 ONLINE       +DATA/RACDB/DATAFILE/sysaux.260.1245022911
         4 ONLINE       +DATA/RACDB/DATAFILE/undotbs1.261.1245022937
         5 SYSTEM       +DATA/RACDB/86B637B62FE07A65E053F706E80A27CA/DATAFILE/system.270.1245023949
         6 ONLINE       +DATA/RACDB/86B637B62FE07A65E053F706E80A27CA/DATAFILE/sysaux.271.1245023949
         7 ONLINE       +DATA/RACDB/DATAFILE/users.262.1245022937
         8 ONLINE       +DATA/RACDB/86B637B62FE07A65E053F706E80A27CA/DATAFILE/undotbs1.272.1245023949
         9 ONLINE       +DATA/RACDB/DATAFILE/undotbs2.274.1245024191
        10 SYSTEM       +DATA/RACDB/5C6CE2BB5DDF685AE063DE01F40A88AD/DATAFILE/system.281.1245025097
        11 ONLINE       +DATA/RACDB/5C6CE2BB5DDF685AE063DE01F40A88AD/DATAFILE/sysaux.280.1245025097
        12 ONLINE       +DATA/RACDB/5C6CE2BB5DDF685AE063DE01F40A88AD/DATAFILE/undotbs1.279.1245025097
        13 ONLINE       +DATA/RACDB/5C6CE2BB5DDF685AE063DE01F40A88AD/DATAFILE/undo_2.283.1245025113
        14 ONLINE       +DATA/RACDB/5C6CE2BB5DDF685AE063DE01F40A88AD/DATAFILE/users.284.1245025115

13 rows selected.
```

### 11.7 ASM Disk Groups (v$asm_diskgroup)

```sql
SQL> SELECT group_number, name, state, type, total_mb, free_mb FROM v$asm_diskgroup;

GROUP_NUMBER NAME            STATE        TYPE       TOTAL_MB    FREE_MB
------------ --------------- ------------ ---------- ---------- ----------
           1 DATA            CONNECTED    EXTERN       81920      70604
```

### 11.8 Redo Log Threads

```sql
SQL> SELECT thread#, group#, members, bytes/1024/1024 AS size_mb, status FROM v$log ORDER BY thread#, group#;

   THREAD#     GROUP#    MEMBERS    SIZE_MB STATUS
---------- ---------- ---------- ---------- ----------------
         1          1          1       1024 CURRENT
         1          2          1       1024 INACTIVE
         2          3          1       1024 INACTIVE
         2          4          1       1024 CURRENT
```

### 11.9 Database Parameters

```sql
SQL> SELECT name, value FROM v$parameter WHERE name IN ('cluster_database','instance_name','db_name','service_names');

NAME                                     VALUE
---------------------------------------- --------------------------------------------------
service_names                            RACDB
cluster_database                         TRUE
instance_name                            RACDB1
db_name                                  RACDB
```

### 11.10 Registered Services (gv$services)

```sql
SQL> SELECT inst_id, name FROM gv$services ORDER BY inst_id, name;

   INST_ID NAME
---------- ------------------------------
         1 RACDB
         1 RACDBXDB
         1 SYS$BACKGROUND
         1 SYS$USERS
         1 orclpdb
         1 racpdb
         2 RACDB
         2 RACDBXDB
         2 SYS$BACKGROUND
         2 SYS$USERS
         2 orclpdb
         2 racpdb

12 rows selected.
```

### 11.11 Sessions by Instance

```sql
SQL> SELECT inst_id, username, COUNT(*) as session_count FROM gv$session WHERE username IS NOT NULL GROUP BY inst_id, username ORDER BY inst_id, username;

INST_ID USERNAME             SESSION_COUNT
------- -------------------- -------------
      1 SYS                           5
      1 SYSRAC                        6
      2 SYS                           4
      2 SYSRAC                        6
```

---

## 12. Listener Details

### 12.1 DBLSNR Listener (Database Listener)

```bash
$ lsnrctl status DBLSNR

LSNRCTL for Linux: Version 19.0.0.0.0 - Production on 27-SEP-2026 00:55:31

Copyright (c) 1991, 2026, Oracle.  All rights reserved.

Connecting to (DESCRIPTION=(ADDRESS=(PROTOCOL=IPC)(KEY=DBLSNR)))
STATUS of the LISTENER
------------------------
Alias                     DBLSNR
Version                   TNSLSNR for Linux: Version 19.0.0.0.0 - Production
Start Date                27-SEP-2026 00:18:41
Uptime                    0 days 0 hr. 36 min. 49 sec
Trace Level               off
Security                  ON: Local OS Authentication
SNMP                      OFF
Listener Parameter File   /u01/app/19c/grid/network/admin/listener.ora
Listener Log File         /u01/app/grid/diag/tnslsnr/racnode1-0/dblsnr/alert/log.xml
Listening Endpoints Summary...
  (DESCRIPTION=(ADDRESS=(PROTOCOL=ipc)(KEY=DBLSNR)))
  (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=10.244.1.222)(PORT=31523)))
  (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=10.244.1.222)(PORT=31522)))
Services Summary...
Service "+ASM" has 1 instance(s).
  Instance "+ASM1", status READY, has 1 handler(s) for this service...
Service "+ASM_DATA" has 1 instance(s).
  Instance "+ASM1", status READY, has 1 handler(s) for this service...
Service "5c6ce2bb5ddf685ae063de01f40a88ad" has 1 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
Service "RACDB" has 1 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
Service "RACDBXDB" has 1 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
Service "orclpdb" has 1 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
Service "racpdb" has 1 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
The command completed successfully
```

### 12.2 SCAN Listener (LISTENER_SCAN1)

```bash
$ lsnrctl status LISTENER_SCAN1

LSNRCTL for Linux: Version 19.0.0.0.0 - Production on 27-SEP-2026 00:55:33

Copyright (c) 1991, 2026, Oracle.  All rights reserved.

Connecting to (DESCRIPTION=(ADDRESS=(PROTOCOL=IPC)(KEY=LISTENER_SCAN1)))
STATUS of the LISTENER
------------------------
Alias                     LISTENER_SCAN1
Version                   TNSLSNR for Linux: Version 19.0.0.0.0 - Production
Start Date                26-SEP-2026 19:41:55
Uptime                    0 days 5 hr. 13 min. 38 sec
Trace Level               off
Security                  ON: Local OS Authentication
SNMP                      OFF
Listener Parameter File   /u01/app/19c/grid/network/admin/listener.ora
Listener Log File         /u01/app/grid/diag/tnslsnr/racnode1-0/listener_scan1/alert/log.xml
Listening Endpoints Summary...
  (DESCRIPTION=(ADDRESS=(PROTOCOL=ipc)(KEY=LISTENER_SCAN1)))
  (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=10.244.1.222)(PORT=1521)))
Services Summary...
Service "5c6ce2bb5ddf685ae063de01f40a88ad" has 2 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
  Instance "RACDB2", status READY, has 1 handler(s) for this service...
Service "RACDB" has 2 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
  Instance "RACDB2", status READY, has 1 handler(s) for this service...
Service "RACDBXDB" has 2 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
  Instance "RACDB2", status READY, has 1 handler(s) for this service...
Service "orclpdb" has 2 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
  Instance "RACDB2", status READY, has 1 handler(s) for this service...
Service "racpdb" has 2 instance(s).
  Instance "RACDB1", status READY, has 1 handler(s) for this service...
  Instance "RACDB2", status READY, has 1 handler(s) for this service...
The command completed successfully
```

---

## 13. Grid Infrastructure Details

### 13.1 Cluster Interconnect Configuration

```bash
$ oifcfg getif

ens1  192.168.10.0  global  cluster_interconnect,asm
ens2  192.168.11.0  global  cluster_interconnect,asm
eth0  10.244.0.0  global  public
```

### 13.2 Cluster Node Details

```bash
$ olsnodes -n -i

racnode1-0      1       <none>
racnode2-0      2       <none>
```

### 13.3 Complete CRS Resource Status

```bash
$ crsctl stat res -t

--------------------------------------------------------------------------------
Name           Target  State        Server                   State details
--------------------------------------------------------------------------------
Local Resources
--------------------------------------------------------------------------------
ora.DBLSNR.lsnr
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
ora.LISTENER.lsnr
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
ora.chad
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
ora.net1.network
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
ora.ons
               ONLINE  ONLINE       racnode1-0               STABLE
               ONLINE  ONLINE       racnode2-0               STABLE
--------------------------------------------------------------------------------
Cluster Resources
--------------------------------------------------------------------------------
ora.ASMNET1LSNR_ASM.lsnr(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.ASMNET2LSNR_ASM.lsnr(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.DATA.dg(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.LISTENER_SCAN1.lsnr
      1        ONLINE  ONLINE       racnode1-0               STABLE
ora.LISTENER_SCAN2.lsnr
      1        ONLINE  ONLINE       racnode2-0               STABLE
ora.asm(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               Started,STABLE
      2        ONLINE  ONLINE       racnode2-0               Started,STABLE
ora.asmnet1.asmnetwork(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.asmnet2.asmnetwork(ora.asmgroup)
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.cvu
      1        ONLINE  ONLINE       racnode1-0               STABLE
ora.racdb.db
      1        ONLINE  ONLINE       racnode1-0               Open,HOME=/u01/app/o
                                                             racle/product/19c/db
                                                             home_1,STABLE
      2        ONLINE  ONLINE       racnode2-0               Open,HOME=/u01/app/o
                                                             racle/product/19c/db
                                                             home_1,STABLE
ora.racdb.racpdb.svc
      1        ONLINE  ONLINE       racnode1-0               STABLE
      2        ONLINE  ONLINE       racnode2-0               STABLE
ora.racnode1-0.vip
      1        ONLINE  ONLINE       racnode1-0               STABLE
ora.racnode2-0.vip
      1        ONLINE  ONLINE       racnode2-0               STABLE
ora.scan1.vip
      1        ONLINE  ONLINE       racnode1-0               STABLE
ora.scan2.vip
      1        ONLINE  ONLINE       racnode2-0               STABLE
--------------------------------------------------------------------------------
```

---

## 14. RacDatabase Custom Resource Full YAML

```yaml
apiVersion: database.oracle.com/v4
kind: RacDatabase
metadata:
  name: racdb01
  namespace: rac
spec:
  asmDiskGroupDetails:
  - disks:
    - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001
    - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002
    name: DATA
    redundancy: EXTERNAL
    type: CRSDG
  configParams:
    cpuCount: 4
    dbBase: /u01/app/oracle
    dbCharSet: AL32UTF8
    dbHome: /u01/app/oracle/product/19c/dbhome_1
    dbName: RACDB
    dbSwZipFile: LINUX.X64_193000_db_home.zip
    gridBase: /u01/app/grid
    gridHome: /u01/app/19c/grid
    gridSwZipFile: LINUX.X64_193000_grid_home.zip
    hostSwStageLocation: /scratch/software/stage
    inventory: /u01/app/oraInventory
    oPatchLocation: /scratch/software/stage/19c/19.29/OPATCH
    oPatchSwZipFile: p6880880_190000_Linux-x86-64.zip
    pdbName: RACPDB
    pgaSize: 2G
    processes: 1000
    ruPatchLocation: /scratch/software/stage/19c/19.29/RU/39467003
    sgaSize: 8G
  envVars:
  - name: LOG_DIR
    value: /tmp/orod
  - name: IGNORE_CRS_PREREQS
    value: "true"
  - name: IGNORE_DB_PREREQS
    value: "true"
  image: container-registry.oracle.com/database/rac_ru:latest-19
  imagePullPolicy: IfNotPresent
  imagePullSecret: oracle-container-registry-secret
  instanceDetails:
    baseLsnrTargetPort: 31522
    baseOnsTargetPort: 30200
    nodeCount: 2
    privateIPDetails:
    - interface: ens1
      name: rac-priv1
    - interface: ens2
      name: rac-priv2
    racHostSwLocation: /scratch/rac/cluster01
    racNodeName: racnode
    workerNodeSelector:
      raccluster: raccluster01
  resources:
    limits:
      cpu: "6"
      memory: 18Gi
    requests:
      cpu: "4"
      memory: 16Gi
  scanSvcName: racnode-scan
  scanSvcTargetPort: 31521
  securityContext:
    sysctls:
    - name: kernel.shmall
      value: "4194304"
    - name: kernel.sem
      value: 250 32000 100 128
    - name: kernel.shmmax
      value: "17179869184"
    - name: kernel.shmmni
      value: "4096"
    - name: net.ipv4.conf.all.rp_filter
      value: "2"
  serviceDetails:
    name: racpdb
  sshKeySecret:
    name: ssh-key-secret
    privKeySecretName: ssh-privkey
    pubKeySecretName: ssh-pubkey
status:
  asmDiskGroups:
  - disks:
    - name: /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001
      sizeInGb: 40
      valid: true
    - name: /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002
      sizeInGb: 40
      valid: true
    name: DATA
    redundancy: EXTERN
    type: CRSDG
  clientEtcHost:
  - 192.168.137.221    racnode1-0.rac.svc.cluster.local racnode1-0-vip.rac.svc.cluster.local    racnode-scan.rac.svc.cluster.local
  - 192.168.137.222    racnode2-0.rac.svc.cluster.local racnode2-0-vip.rac.svc.cluster.local    racnode-scan.rac.svc.cluster.local
  connectString: racnode-scan:1521/RACDB
  dbState: OPEN
  externalConnectString: racnode-scan.rac.svc.cluster.local:31521/racpdb
  pdbConnectString: racnode-scan:1521/racpdb
  racNodes:
  - name: racnode1-0
    nodeDetails:
      InstanceState: OPEN
      PodState: AVAILABLE
      clusterState: HEALTHY
      state: AVAILABLE
  - name: racnode2-0
    nodeDetails:
      InstanceState: OPEN
      PodState: AVAILABLE
      clusterState: HEALTHY
      state: AVAILABLE
  releaseUpdate: 19.32.0.0.0
  role: PRIMARY
  serviceDetails:
    name: racpdb
    svcState: service racpdb is running on instance(s) racdb1,racdb2
  state: AVAILABLE
```

---

## Summary

| Check | Status |
|-------|--------|
| Kubernetes Pods | ✅ 2/2 Running |
| Kubernetes Services | ✅ 10 Services Created |
| RacDatabase CR | ✅ AVAILABLE, OPEN, PRIMARY |
| CRS Cluster | ✅ Online on both nodes |
| CRS Resources | ✅ All ONLINE/STABLE |
| Database Instances | ✅ RACDB1, RACDB2 Open |
| PDB | ✅ ORCLPDB READ WRITE |
| ASM | ✅ Running on both nodes |
| ASM Disk Group | ✅ DATA MOUNTED (81GB, 70GB free) |
| SCAN Listeners | ✅ Running on both nodes |
| DBLSNR Listeners | ✅ Running, 7 services registered |
| Grid Patches | ✅ 19.32.0.0.0 RU Applied |
| DB Patches | ✅ 19.32.0.0.0 RU Applied |
| Redo Logs | ✅ 4 groups (2 per thread), 1GB each |
| Sessions | ✅ Active on both instances |
| Services | ✅ racpdb running on both instances |
| Setup State | ✅ completed |

---

**Verification Complete - Oracle RAC Deployment Successful!**

**Document Generated:** September 27, 2026
