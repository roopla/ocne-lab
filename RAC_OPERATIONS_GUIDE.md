# Oracle RAC Operations Guide

This guide documents common operations for managing Oracle RAC on Kubernetes using the Oracle Database Operator.

## Environment Details

- **Kubernetes Namespace**: `rac`
- **Pod Names**: `racnode1-0`, `racnode2-0`
- **Database Name**: RACDB
- **Instance Names**: RACDB1 (racnode1-0), RACDB2 (racnode2-0)
- **Service Name**: racpdb
- **PDB Name**: ORCLPDB

## Accessing RAC Pods

All commands are executed from the operator node (`ocne-op`) using kubectl exec:

```bash
# General pattern for running srvctl commands
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl <command>"'

# General pattern for running crsctl commands
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "crsctl <command>"'
```

---

## 1. Cluster Status Commands

### Check CRS Status

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "crsctl check crs"'
```

**Output:**
```
CRS-4638: Oracle High Availability Services is online
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
```

### Check Cluster Status (All Nodes)

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "crsctl check cluster -all"'
```

**Output:**
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

### List Cluster Nodes

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "olsnodes -n -t"'
```

**Output:**
```
racnode1-0	1	Unpinned
racnode2-0	2	Unpinned
```

### View All CRS Resources

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "crsctl stat res -t"'
```

**Output:**
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

---

## 2. Database Operations

### Check Database Status

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status database -d RACDB -v"'
```

**Output:**
```
Instance RACDB1 is running on node racnode1-0 with online services racpdb. Instance status: Open.
Instance RACDB2 is running on node racnode2-0 with online services racpdb. Instance status: Open.
```

### View Database Configuration

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl config database -d RACDB"'
```

**Output:**
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

### Stop Database (All Instances)

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl stop database -d RACDB -o immediate"'
```

**Verification:**
```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status database -d RACDB -v"'
```

**Output after stop:**
```
Instance RACDB1 is not running on node racnode1-0
Instance RACDB2 is not running on node racnode2-0
```

### Start Database (All Instances)

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl start database -d RACDB"'
```

**Verification output:**
```
Instance RACDB1 is running on node racnode1-0 with online services racpdb. Instance status: Open.
Instance RACDB2 is running on node racnode2-0 with online services racpdb. Instance status: Open.
```

---

## 3. Instance Operations

### Stop a Single Instance

**Note:** Use `-force` flag when services are running on the instance.

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl stop instance -d RACDB -i RACDB1 -o immediate -force"'
```

**Verification:**
```
Instance RACDB1 is not running on node racnode1-0
Instance RACDB2 is running on node racnode2-0 with online services racpdb. Instance status: Open.
```

### Start a Single Instance

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl start instance -d RACDB -i RACDB1"'
```

**Verification:**
```
Instance RACDB1 is running on node racnode1-0 with online services racpdb. Instance status: Open.
Instance RACDB2 is running on node racnode2-0 with online services racpdb. Instance status: Open.
```

### Common Instance Stop Options

| Option | Description |
|--------|-------------|
| `-o immediate` | Immediate shutdown (default if not specified) |
| `-o transactional` | Wait for active transactions to complete |
| `-o abort` | Abort shutdown (use with caution) |
| `-force` | Force stop even if services are running |

---

## 4. Service Operations

### Check Service Status

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status service -d RACDB"'
```

**Output:**
```
Service racpdb is running on instance(s) RACDB1,RACDB2
```

### View Service Configuration

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl config service -d RACDB -s racpdb"'
```

**Output:**
```
Service name: racpdb
Server pool:
Cardinality: 2
Service role: PRIMARY
Management policy: AUTOMATIC
DTP transaction: false
AQ HA notifications: false
Global: false
Commit Outcome: false
Failover type:
Failover method:
Failover retries:
Failover delay:
Failover restore: NONE
Connection Load Balancing Goal: LONG
Runtime Load Balancing Goal: NONE
TAF policy specification: NONE
Edition:
Pluggable database name: ORCLPDB
Hub service:
Maximum lag time: ANY
SQL Translation Profile:
Retention: 86400 seconds
Replay Initiation Time: 300 seconds
Drain timeout:
Stop option:
Session State Consistency: DYNAMIC
GSM Flags: 0
Service is enabled
Preferred instances: RACDB1,RACDB2
Available instances:
CSS critical: no
Service uses Java: false
```

### Stop Service on Specific Instance

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl stop service -d RACDB -s racpdb -i RACDB1"'
```

**Verification:**
```
Service racpdb is running on instance(s) RACDB2
```

### Start Service on Specific Instance

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl start service -d RACDB -s racpdb -i RACDB1"'
```

**Verification:**
```
Service racpdb is running on instance(s) RACDB1,RACDB2
```

### Relocate Service Between Instances

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl relocate service -d RACDB -s racpdb -i RACDB1 -t RACDB2"'
```

**Note:** This will fail if the service is already running on both instances:
```
PRCD-1346 : failed to relocate services of database RACDB
PRCR-1089 : Failed to relocate resource ora.racdb.racpdb.svc.
CRS-5702: Resource 'ora.racdb.racpdb.svc' is already running on 'racnode2-0'
```

---

## 5. Listener Operations

### Check Listener Status

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status listener"'
```

**Output:**
```
Listener DBLSNR is enabled
Listener DBLSNR is running on node(s): racnode1-0,racnode2-0
Listener LISTENER is enabled
Listener LISTENER is running on node(s): racnode1-0,racnode2-0
```

### Stop Listener on Specific Node

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl stop listener -l LISTENER -n racnode1-0"'
```

**Verification:**
```
Listener DBLSNR is enabled
Listener DBLSNR is running on node(s): racnode1-0,racnode2-0
Listener LISTENER is enabled
Listener LISTENER is running on node(s): racnode2-0
```

### Start Listener on Specific Node

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl start listener -l LISTENER -n racnode1-0"'
```

---

## 6. SCAN Listener Operations

### Check SCAN Listener Status

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status scan_listener"'
```

**Output:**
```
SCAN Listener LISTENER_SCAN1 is enabled
SCAN listener LISTENER_SCAN1 is running on node racnode1-0
SCAN Listener LISTENER_SCAN2 is enabled
SCAN listener LISTENER_SCAN2 is running on node racnode2-0
```

### Stop SCAN Listener

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl stop scan_listener -i 1"'
```

**Verification:**
```
SCAN Listener LISTENER_SCAN1 is enabled
SCAN listener LISTENER_SCAN1 is not running
SCAN Listener LISTENER_SCAN2 is enabled
SCAN listener LISTENER_SCAN2 is running on node racnode2-0
```

### Start SCAN Listener

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl start scan_listener -i 1"'
```

### Check SCAN VIP Status

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status scan"'
```

**Output:**
```
SCAN VIP scan1 is enabled
SCAN VIP scan1 is running on node racnode1-0
SCAN VIP scan2 is enabled
SCAN VIP scan2 is running on node racnode2-0
```

---

## 7. VIP and Network Operations

### Check VIP Status on a Node

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status vip -n racnode1-0"'
```

**Output:**
```
VIP 10.244.1.222 is enabled
VIP 10.244.1.222 is running on node: racnode1-0
```

### Check Node Applications Status

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status nodeapps"'
```

**Output:**
```
VIP 10.244.1.222 is enabled
VIP 10.244.1.222 is running on node: racnode1-0
VIP 10.244.2.53 is enabled
VIP 10.244.2.53 is running on node: racnode2-0
Network is enabled
Network is running on node: racnode1-0
Network is running on node: racnode2-0
ONS is enabled
ONS daemon is running on node: racnode1-0
ONS daemon is running on node: racnode2-0
```

---

## 8. ASM Operations

### Check ASM Status

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status asm"'
```

**Output:**
```
ASM is running on racnode1-0,racnode2-0
```

### Check Diskgroup Status

```bash
kubectl exec racnode1-0 -n rac -- bash -c 'su - grid -c "srvctl status diskgroup -g DATA"'
```

**Output:**
```
Disk Group DATA is running on racnode1-0,racnode2-0
```

---

## 9. Kubernetes-Level Operations

### Check RAC Database Custom Resource

```bash
kubectl get racdatabases -n rac
```

**Output:**
```
NAMESPACE   NAME      DBNAME   DBSTATE   ROLE      VERSION       PDB CONNECT STR            STATE
rac         racdb01   RACDB    OPEN      PRIMARY   19.32.0.0.0   racnode-scan:1521/racpdb   AVAILABLE
```

### Check RAC Pod Status

```bash
kubectl get pods -n rac -o wide
```

**Output:**
```
NAME         READY   STATUS    RESTARTS   AGE    IP             NODE                NOMINATED NODE   READINESS GATES
racnode1-0   1/1     Running   0          7h     10.244.1.222   ocne-w1.lab.local   <none>           <none>
racnode2-0   1/1     Running   0          7h     10.244.2.53    ocne-w2.lab.local   <none>           <none>
```

### View Pod Logs

```bash
# View logs for racnode1
kubectl logs racnode1-0 -n rac -c racnode1-0

# Follow logs in real-time
kubectl logs -f racnode1-0 -n rac -c racnode1-0
```

### Describe RAC Database Resource

```bash
kubectl describe racdatabase racdb01 -n rac
```

---

## 10. Common Error Scenarios

### Error: Cannot Stop Instance Due to Running Services

**Error:**
```
PRCD-1131 : Failed to stop database RACDB and its services
CRS-2974: unable to act on resource 'ora.racdb.db'... force flag was not specified
```

**Solution:** Add the `-force` flag:
```bash
srvctl stop instance -d RACDB -i RACDB1 -o immediate -force
```

### Error: Cannot Relocate SCAN VIP

**Error:**
```
PRCR-1105 : Failed to relocate resource ora.scan1.vip to node racnode2-0
CRS-2718: Server 'racnode2-0' is not a hosting member of resource 'ora.scan1.vip'
```

**Explanation:** SCAN VIPs are tied to specific server pools and cannot be freely relocated between nodes that are not configured as hosting members.

### Error: Service Already Running on Target

**Error:**
```
PRCD-1346 : failed to relocate services of database RACDB
CRS-5702: Resource 'ora.racdb.racpdb.svc' is already running on 'racnode2-0'
```

**Explanation:** The service is already running on the target instance. Relocation is only applicable when moving a service from one instance to another.

---

## 11. Best Practices

### Before Stopping Components

1. **Check dependent resources** - Stopping listeners affects database connectivity
2. **Notify users** - Schedule maintenance windows
3. **Use rolling operations** - Stop one instance at a time for HA
4. **Verify service failover** - Ensure services relocate properly

### Recommended Stop Order (Full Maintenance)

1. Stop database services on the target node
2. Stop the database instance
3. Stop local listeners
4. (Optional) Stop SCAN listener if relocating SCAN
5. Perform maintenance
6. Reverse the process to start

### Recommended Start Order

1. Verify CRS is running (`crsctl check crs`)
2. Verify ASM is running (`srvctl status asm`)
3. Start listeners (`srvctl start listener`)
4. Start database instance (`srvctl start instance`)
5. Start/verify services (`srvctl start service`)

---

## 12. Quick Reference

| Component | Status Command | Stop Command | Start Command |
|-----------|---------------|--------------|---------------|
| Database | `srvctl status database -d RACDB -v` | `srvctl stop database -d RACDB -o immediate` | `srvctl start database -d RACDB` |
| Instance | `srvctl status instance -d RACDB -i RACDB1` | `srvctl stop instance -d RACDB -i RACDB1 -force` | `srvctl start instance -d RACDB -i RACDB1` |
| Service | `srvctl status service -d RACDB` | `srvctl stop service -d RACDB -s racpdb` | `srvctl start service -d RACDB -s racpdb` |
| Listener | `srvctl status listener` | `srvctl stop listener -l LISTENER -n racnode1-0` | `srvctl start listener -l LISTENER -n racnode1-0` |
| SCAN | `srvctl status scan_listener` | `srvctl stop scan_listener -i 1` | `srvctl start scan_listener -i 1` |
| ASM | `srvctl status asm` | N/A (managed by CRS) | N/A |
| CRS | `crsctl check crs` | N/A (container-managed) | N/A |

---

*Document generated: September 2026*
*Lab Environment: OCNE 1.9 + Oracle Database Operator v4*
