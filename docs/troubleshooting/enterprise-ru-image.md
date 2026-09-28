# Troubleshooting: Oracle Database enterprise_ru Image Issues

## Problem Summary

The `container-registry.oracle.com/database/enterprise_ru:latest-19` image fails to complete database creation due to Kubernetes liveness/readiness probe timeouts.

---

## Symptoms

1. **Pod keeps restarting** during database creation
2. **Readiness probe failures** (80+ failures observed)
3. **Database creation stuck at 36%** - "Creating and starting Oracle instance"
4. **Pod restarts every 15-20 minutes** before database creation completes

### Example Pod Status
```bash
NAME                 READY   STATUS    RESTARTS      AGE
sidb-primary-mm8qc   0/1     Running   4 (55m ago)   116m
```

### Event Log
```
Warning  Unhealthy  10m (x80 over 46m)  kubelet  Readiness probe failed:
```

---

## Root Cause Analysis

### 1. Image Size and Complexity
- `enterprise_ru:latest-19` is a Release Update (RU) patched image
- Contains more patches and components than base `enterprise:19.3.0.0`
- Database creation takes longer due to additional datapatch operations

### 2. Probe Timeout Mismatch
- Default Kubernetes liveness/readiness probes timeout too quickly
- Database creation with enterprise_ru takes 30-45+ minutes
- Probes fail before DBCA completes, causing pod restart
- Each restart resets database creation from 0%

### 3. NFS Performance Impact
- NFS storage adds latency compared to local block storage
- Datafile creation and redo log operations slower on NFS
- Compounds the timeout issue

---

## Attempted Solutions

### 1. Increased Memory (16Gi)
```yaml
resources:
  requests:
    cpu: "4"
    memory: "16Gi"
  limits:
    cpu: "8"
    memory: "20Gi"
```
**Result:** Pod still restarted after ~20 minutes

### 2. Monitoring Alert Log
The database was actively creating (datafiles growing, redo logs switching) but DBCA stdout was buffered:
```
Resize operation completed for file# 4, fname /opt/oracle/oradata/ORCL/undotbs01.dbf
Thread 1 advanced to log sequence 7 (LGWR switch)
```

---

## Working Solution

Use the base `enterprise:19.3.0.0` image instead:
```yaml
image:
  pullFrom: container-registry.oracle.com/database/enterprise:19.3.0.0
```

**Tradeoffs:**
- Missing `configDataguardPrereqs.sh` script (manual workaround needed)
- Older patch level (can be patched post-creation)
- Database creates successfully in ~20 minutes

---

## Manual Data Guard Prerequisites Script

Since `enterprise:19.3.0.0` lacks the Data Guard prereqs script, create it manually:

```bash
kubectl exec -n sidb <pod-name> -- bash -c 'cat > /opt/oracle/configDataguardPrereqs.sh << "EOSCRIPT"
#!/bin/bash
# Dummy Data Guard Prerequisites script
# Prerequisites already configured manually
echo "Data Guard prerequisites configuration complete"
exit 0
EOSCRIPT
chmod +x /opt/oracle/configDataguardPrereqs.sh'
```

Then manually configure Data Guard prerequisites:
```sql
-- Add standby redo logs
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 200M;

-- Enable Data Guard Broker
ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH;

-- Configure archive destinations
ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(ORCL,ORCLS)' SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=ORCL' SCOPE=BOTH;
ALTER SYSTEM SET FAL_SERVER='ORCLS' SCOPE=BOTH;
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH;
```

---

## Alternative Solutions (Not Tested)

### 1. Use Prebuilt Database Image
Build a custom image with prebuilt database to skip DBCA:
- Faster startup (minutes instead of 30+)
- Requires custom image build process

### 2. Modify Operator Deployment
Patch the operator to use longer probe timeouts:
- Requires operator code modification
- Not recommended for production

### 3. Use OCI or Cloud Block Storage
Faster I/O than NFS may help:
- Reduces database creation time
- May avoid probe timeouts

---

## Authentication Issue (Separate Problem)

### Symptom
```
E0923 21:00:35.836085 remote_image.go:180] "PullImage from image service failed"
err="rpc error: code = Unknown desc = unable to retrieve auth token: invalid username/password: authentication required"
```

### Cause
Oracle Container Registry requires **separate license acceptance** for each repository:
- `database/enterprise` - base Enterprise Edition
- `database/enterprise_ru` - Enterprise Edition with Release Updates (separate license)

### Resolution
1. Go to https://container-registry.oracle.com
2. Sign in with Oracle SSO
3. Navigate to **Database** > **enterprise_ru**
4. Accept the license agreement
5. Wait a few minutes for propagation
6. Recreate the Kubernetes pull secret

---

## Lessons Learned

1. **Image choice matters** - base images may be more reliable than RU images for initial deployment
2. **Probe timeouts** - database creation can exceed default Kubernetes probe limits
3. **Monitor alert log** - DBCA stdout is buffered; alert log shows real progress
4. **NFS adds latency** - plan for longer creation times with network storage
5. **License acceptance** - each OCR repository requires separate license agreement
