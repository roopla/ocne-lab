# Oracle RAC Operator: Software Detection and Configuration Workflow

This document details exactly how the Oracle Database Operator detects existing software installations and avoids redundant extraction/configuration on subsequent pod restarts.

---

## Overview

The operator uses a combination of:
1. **Filesystem checks** - Does the software exist on disk?
2. **Binary execution** - Can Oracle tools run successfully?
3. **Runtime flags** - Environment variables set during execution

```mermaid
flowchart TB
    subgraph checks["Detection Checks"]
        C1["Filesystem Checks<br/>/u01/app/19c/grid/bin/cluvfy<br/>/etc/oracle/"]
        C2["Binary Execution<br/>oraversion -majorVersion<br/>cluvfy comp software"]
        C3["Runtime Flags<br/>GI_SW_UNZIPPED_FLAG<br/>GI_HOME_CONFIGURED_FLAG"]
    end

    subgraph decision["Decision"]
        D1{"All checks pass?"}
    end

    subgraph action["Action"]
        A1["SKIP extraction<br/>SKIP configuration<br/>Just START services"]
        A2["RUN extraction<br/>RUN configuration<br/>Full setup"]
    end

    checks --> decision
    D1 -->|"Yes"| A1
    D1 -->|"No"| A2

    style A1 fill:#90EE90
    style A2 fill:#FFB6C1
```

---

## Runtime Flags (Environment Variables)

These flags are set in the `ora_env_dict` dictionary during script execution:

| Flag | Set When | Purpose |
|------|----------|---------|
| `GI_SW_UNZIPPED_FLAG` | Software zip extracted to hostPath | Skip `check_home()` call |
| `GI_HOME_INSTALLED_FLAG` | `check_home()` returns 0 | Indicates binaries exist |
| `GI_HOME_CONFIGURED_FLAG` | `check_gi_installed()` returns True | Skip ALL Grid setup |
| `RAC_SW_UNZIPPED_FLAG` | DB software zip extracted | Skip DB home check |
| `COPY_GRID_SOFTWARE` | Staging location has zip files | Triggers extraction |
| `CLUSTER_SETUP_FLAG` | Grid configuration completes | Cluster is running |

---

## Detailed Detection Flow

### Phase 1: Environment Setup (orasetupenv.py)

```mermaid
flowchart TB
    START["Container Starts"] --> ENV["Load environment variables"]

    ENV --> CHECK_STAGE{"STAGING_SOFTWARE_LOC<br/>and GRID_SW_ZIP_FILE<br/>set?"}

    CHECK_STAGE -->|"No"| NO_STAGE["No staged software<br/>Skip _setup_software()"]
    CHECK_STAGE -->|"Yes"| CHECK_ZIP{"ZIP file exists<br/>at staging location?"}

    CHECK_ZIP -->|"No (secondary node)"| COPY_FROM["Will copy from<br/>primary node later"]
    CHECK_ZIP -->|"Yes"| CHECK_HOME_EMPTY{"hostPath /u01<br/>home directory<br/>empty?"}

    CHECK_HOME_EMPTY -->|"No"| SKIP_UNZIP["Log: 'home directory<br/>is not empty'<br/>Skip unzip"]
    CHECK_HOME_EMPTY -->|"Yes"| DO_UNZIP["Unzip software<br/>to hostPath"]

    DO_UNZIP --> SET_FLAG1["Set FLAG:<br/>GI_SW_UNZIPPED_FLAG=true"]

    SKIP_UNZIP --> BANNER["Continue to<br/>set_banner()"]
    SET_FLAG1 --> BANNER
    NO_STAGE --> BANNER
    COPY_FROM --> BANNER

    style SET_FLAG1 fill:#FFD700
    style DO_UNZIP fill:#FFB6C1
    style SKIP_UNZIP fill:#90EE90
```

**Key Code** (`orasetupenv.py:545`):
```python
def _setup_software(self, sw_zip_key, copy_key, params_getter, unzip_flag_key, ...):
    # Check if staging location and zip file are configured
    if not (self.ocommon.check_key("STAGING_SOFTWARE_LOC", self.ora_env_dict) and
            self.ocommon.check_key(sw_zip_key, self.ora_env_dict)):
        return  # No staged software configured

    swfile = self.ora_env_dict["STAGING_SOFTWARE_LOC"] + "/" + self.ora_env_dict[sw_zip_key]

    if os.path.isfile(swfile):
        home_files = os.listdir(home)
        if len(home_files) == 0:
            # Home is empty, extract software
            cmd = 'su - {0} -c "unzip -q {1} -d {2}"'.format(user, swfile, home)
            # ... execute unzip ...

            # SET FLAG: Software was just unzipped
            self.ora_env_dict = self.ocommon.add_key(unzip_flag_key, "true", self.ora_env_dict)
        else:
            # Home not empty, skip extraction
            self.ocommon.log_error_message("oracle gi home directory is not empty. skipping software unzipping...")
```

---

### Phase 2: Banner Check (orasetupenv.py)

This phase determines if Grid is already fully configured.

```mermaid
flowchart TB
    BANNER["set_banner()"] --> CHECK_UNZIP{"GI_SW_UNZIPPED_FLAG<br/>set?"}

    CHECK_UNZIP -->|"Yes"| JUST_UNZIPPED["Software just unzipped<br/>Skip home checks<br/>(will configure)"]

    CHECK_UNZIP -->|"No"| CALL_CHECK_HOME["Call check_home()<br/>Verify Grid installation"]

    CALL_CHECK_HOME --> CHECK_HOME_RESULT{"check_home()<br/>returns?"}

    CHECK_HOME_RESULT -->|"0 (success)"| SET_INSTALLED["Set FLAG:<br/>GI_HOME_INSTALLED_FLAG=true"]
    CHECK_HOME_RESULT -->|"1 (failure)"| NOT_INSTALLED["Grid home not valid<br/>or doesn't exist"]

    SET_INSTALLED --> CALL_GI_INSTALLED["Call check_gi_installed()"]
    NOT_INSTALLED --> CALL_GI_INSTALLED

    CALL_GI_INSTALLED --> GI_RESULT{"check_gi_installed()<br/>returns?"}

    GI_RESULT -->|"True"| SET_CONFIGURED["Set FLAG:<br/>GI_HOME_CONFIGURED_FLAG=true<br/><br/>Log: 'Grid is already<br/>installed on this machine'"]

    GI_RESULT -->|"False"| NOT_CONFIGURED["Log: 'Grid is not<br/>installed on this machine'<br/><br/>Will need full setup"]

    SET_CONFIGURED --> CONTINUE["Continue to setup()"]
    NOT_CONFIGURED --> CONTINUE
    JUST_UNZIPPED --> CONTINUE

    style SET_INSTALLED fill:#FFD700
    style SET_CONFIGURED fill:#90EE90
    style NOT_CONFIGURED fill:#FFB6C1
```

**Key Code** (`orasetupenv.py:904`):
```python
def set_banner(self):
    if self.ocommon.check_key("OP_TYPE", self.ora_env_dict):
        # If software was just unzipped, skip the home checks
        if self.ocommon.check_key("GI_SW_UNZIPPED_FLAG", self.ora_env_dict):
            msg = "Since OP_TYPE is set, setup will be initiated..."
            return

        # Check if Grid home exists and is valid
        retcode1 = self.ocvu.check_home(pubhostname, gihome, giuser)

        if retcode1 == 0:
            # Grid home is valid, set installed flag
            self.ora_env_dict = self.ocommon.add_key("GI_HOME_INSTALLED_FLAG", "true", self.ora_env_dict)

        # Check if Grid is fully configured
        status = self.ocommon.check_gi_installed(retcode1, gihome, giuser, pubhostname, invloc)

        if status:
            # Grid is fully configured!
            self.ora_env_dict = self.ocommon.add_key("GI_HOME_CONFIGURED_FLAG", "true", self.ora_env_dict)
```

---

### Phase 3: check_home() - Binary Validation (oracvu.py)

This function validates that Grid software exists and is functional.

```mermaid
flowchart TB
    CHECK_HOME["check_home(node, home, user)"] --> CHECK_CLUVFY{"File exists?<br/>{GRID_HOME}/bin/cluvfy"}

    CHECK_CLUVFY -->|"No"| RETURN_1A["return 1<br/>(failure)"]
    CHECK_CLUVFY -->|"Yes"| RUN_CLUVFY["Run command:<br/>cluvfy comp software -d {home}"]

    RUN_CLUVFY --> CHECK_OUTPUT{"Output contains<br/>'FAILED'?"}

    CHECK_OUTPUT -->|"Yes"| RETURN_1B["return 1<br/>(failure)"]
    CHECK_OUTPUT -->|"No"| RETURN_0["return 0<br/>(success)"]

    style RETURN_0 fill:#90EE90
    style RETURN_1A fill:#FF6B6B
    style RETURN_1B fill:#FF6B6B
    style CHECK_CLUVFY fill:#FFD700
```

**Key Code** (`oracvu.py:217`):
```python
def check_home(self, node, home, user):
    """Check if CRS software is configured properly."""
    giuser, gihome, gbase, oinv = self.ocommon.get_gi_params()

    # CHECK 1: Does cluvfy binary exist?
    cvufile = '{0}/bin/cluvfy'.format(gihome)
    if not self.ocommon.check_file(cvufile, True, None, None):
        return 1  # cluvfy doesn't exist = software not installed

    # CHECK 2: Run cluvfy to validate software installation
    cmd = '''su - {0} -c "{1}/bin/cluvfy comp software -d {2} -verbose"'''.format(user, gihome, home)
    output, error, retcode = self.ocommon.execute_cmd(cmd, None, None)

    if not self.ocommon.check_substr_match(output, "FAILED"):
        return 0  # No failures = software is valid
    else:
        return 1  # Validation failed
```

**Important**: `cluvfy` binary is created during Grid **configuration**, not during extraction. This is why pre-copying from the RU image doesn't skip installation - `cluvfy` doesn't exist in the image!

---

### Phase 4: check_gi_installed() - Configuration Validation (oracommon.py)

This function checks if Grid is fully configured (not just extracted).

```mermaid
flowchart TB
    CHECK_GI["check_gi_installed(retcode1, gihome, giuser, node, oinv)"]

    CHECK_GI --> CHECK_RETCODE{"retcode1 == 0?<br/>(from check_home)"}

    CHECK_RETCODE -->|"No (1)"| GI_NOT_INSTALLED["Log: 'Grid is not installed'<br/>return False"]

    CHECK_RETCODE -->|"Yes (0)"| CHECK_ETC_ORACLE{"Directory exists?<br/>/etc/oracle/"}

    CHECK_ETC_ORACLE -->|"Yes"| FULLY_CONFIGURED["Log: 'Grid is already installed<br/>and /etc/oracle exists.<br/>Skipping Grid setup.'<br/><br/>return True"]

    CHECK_ETC_ORACLE -->|"No"| CHECK_HOME_CONTENT{"Grid home<br/>directory empty?"}

    CHECK_HOME_CONTENT -->|"Yes"| GI_NOT_CONFIGURED["return False"]

    CHECK_HOME_CONTENT -->|"No"| CHECK_INVENTORY["Check inventory<br/>check_home_inv()"]

    CHECK_INVENTORY --> TRY_RESTORE["Try restore from backup:<br/>{GRID_BASE}/.etcoraclebackup/"]

    TRY_RESTORE --> RESTORE_RESULT{"Restore<br/>successful?"}

    RESTORE_RESULT -->|"Yes"| RUN_ORAINSTSH["Run orainstRoot.sh<br/>Start CRS services"]
    RESTORE_RESULT -->|"No"| RESTORE_FAILED["return False"]

    RUN_ORAINSTSH --> START_SUCCESS{"CRS started<br/>successfully?"}

    START_SUCCESS -->|"Yes"| RETURN_TRUE["return True"]
    START_SUCCESS -->|"No"| RETURN_FALSE["return False"]

    style FULLY_CONFIGURED fill:#90EE90
    style GI_NOT_INSTALLED fill:#FF6B6B
    style GI_NOT_CONFIGURED fill:#FF6B6B
    style RESTORE_FAILED fill:#FF6B6B
    style CHECK_ETC_ORACLE fill:#FFD700
```

**Key Code** (`oracommon.py:1933`):
```python
def check_gi_installed(self, retcode1, gihome, giuser, node, oinv):
    """Check if Grid is fully installed and configured."""

    if retcode1 == 0:  # check_home() passed
        # CHECK: Does /etc/oracle directory exist?
        if os.path.isdir("/etc/oracle"):
            # FULLY CONFIGURED - Skip everything!
            bstr = "Grid is already installed on this machine and /etc/oracle also exist. Skipping Grid setup.."
            self.log_info_message(self.print_banner(bstr), self.file_name)
            return True
        else:
            # Software exists but /etc/oracle missing
            # Try to restore from backup
            dir = os.listdir(gihome)
            if len(dir) != 0:
                status = self.check_home_inv(None, gihome, giuser)
                if status:
                    # Restore /etc/oracle from backup
                    status = self.restore_gi_files(gihome, giuser)
                    if status:
                        self.run_orainstsh_local(giuser, node, oinv)
                        status = self.start_crs(gihome, giuser)
                        return status
            return False
    else:
        # check_home() failed - Grid not installed
        self.log_info_message("Grid is not installed on this machine. Proceeding further...", self.file_name)
        return False
```

---

### Phase 5: setup() - Main Installation Logic (oragiprov.py)

This is where the decision to install or skip is made.

```mermaid
flowchart TB
    SETUP["setup()"] --> CHECK_CONFIGURED{"GI_HOME_CONFIGURED_FLAG<br/>set to 'true'?"}

    CHECK_CONFIGURED -->|"Yes"| SKIP_ALL["Log: 'Grid is already<br/>configured on this machine'<br/><br/>SKIP ALL SETUP!<br/>Just backup files and exit"]

    CHECK_CONFIGURED -->|"No"| ENV_CHECKS["Run env_param_checks()<br/>Validate environment"]

    ENV_CHECKS --> SSH_SETUP["perform_ssh_setup()"]

    SSH_SETUP --> CHECK_UNZIP{"GI_SW_UNZIPPED_FLAG<br/>set?"}

    CHECK_UNZIP -->|"Yes"| SKIP_HOME_CHECK["Skip check_home()<br/>(just unzipped)"]
    CHECK_UNZIP -->|"No"| RUN_HOME_CHECK["retcode1 = check_home()"]

    SKIP_HOME_CHECK --> RETCODE_1["retcode1 = 1<br/>(initial value)"]
    RUN_HOME_CHECK --> RETCODE_RESULT{"retcode1 value?"}

    RETCODE_RESULT -->|"0"| HOME_EXISTS["Log: 'Grid home is<br/>already installed'"]
    RETCODE_RESULT -->|"1"| HOME_MISSING["Grid home doesn't exist<br/>or invalid"]

    RETCODE_1 --> CHECK_COPY
    HOME_EXISTS --> CHECK_COPY
    HOME_MISSING --> CHECK_COPY

    CHECK_COPY{"retcode1 != 0<br/>AND<br/>COPY_GRID_SOFTWARE set?"}

    CHECK_COPY -->|"Yes"| DO_INSTALL["crs_sw_install()<br/>Extract/copy software<br/><br/>run_orainstsh()<br/>run_rootsh()"]
    CHECK_COPY -->|"No"| SKIP_INSTALL["Skip software install"]

    DO_INSTALL --> CONFIG
    SKIP_INSTALL --> CONFIG

    CONFIG["crs_config_install()<br/>Configure Grid"]

    CONFIG --> ROOT["run_rootsh()<br/>Run root.sh"]

    ROOT --> POST["run_postroot()<br/>Post-configuration"]

    POST --> VERIFY["Verify cluster health<br/>check_ohasd()<br/>check_clu()"]

    VERIFY --> SET_RUNNING["Set FLAG:<br/>CLUSTER_SETUP_FLAG='running'"]

    SET_RUNNING --> BACKUP["backup_oracle_etc_files()<br/>Save /etc/oracle to<br/>{GRID_BASE}/.etcoraclebackup/"]

    SKIP_ALL --> BACKUP
    BACKUP --> DONE["Setup complete"]

    style SKIP_ALL fill:#90EE90
    style DO_INSTALL fill:#FFB6C1
    style SET_RUNNING fill:#FFD700
    style CHECK_CONFIGURED fill:#FFD700
```

**Key Code** (`oragiprov.py:90`):
```python
def setup(self):
    """This function sets up Grid on this machine."""

    giuser, gihome, obase, invloc = self.ocommon.get_gi_params()
    pubhostname = self.ocommon.get_public_hostname()
    retcode1 = 1  # Default: assume Grid not installed

    # DECISION POINT 1: Was software just unzipped?
    if not self.ocommon.check_key("GI_SW_UNZIPPED_FLAG", self.ora_env_dict):
        # No, check if Grid home exists
        retcode1 = self.ocvu.check_home(pubhostname, gihome, giuser)

    if retcode1 == 0:
        bstr = "Grid home is already installed on this machine"
        self.ocommon.log_info_message(self.ocommon.print_banner(bstr), self.file_name)

    # DECISION POINT 2: Is Grid already configured?
    if self.ocommon.check_key("GI_HOME_CONFIGURED_FLAG", self.ora_env_dict):
        bstr = "Grid is already configured on this machine"
        self.ocommon.log_info_message(self.ocommon.print_banner(bstr), self.file_name)
        # SKIP EVERYTHING - just backup and exit
    else:
        # Full setup required
        self.env_param_checks()
        self.perform_ssh_setup()

        # DECISION POINT 3: Need to install software?
        if retcode1 != 0 and self.ocommon.check_key("COPY_GRID_SOFTWARE", self.ora_env_dict):
            self.crs_sw_install()  # Extract/copy software
            self.run_orainstsh()
            self.run_rootsh()

        # Configure Grid
        gridrsp = self.crs_config_install()
        self.run_rootsh()
        self.run_postroot(gridrsp)

        # Verify and set running flag
        self.ora_env_dict = self.ocommon.add_key("CLUSTER_SETUP_FLAG", "running", self.ora_env_dict)

    # Always backup /etc/oracle for next restart
    self.backup_oracle_etc_files()
```

---

## Complete Lifecycle: Fresh Install vs Pod Restart

### Fresh Installation (First Time)

```mermaid
sequenceDiagram
    participant Pod
    participant Scripts
    participant hostPath as hostPath (/u01)
    participant EtcOracle as /etc/oracle
    participant Backup as .etcoraclebackup

    Note over Pod: Container starts fresh

    Pod->>hostPath: Mount empty directory
    Scripts->>hostPath: Check: is home empty?
    hostPath-->>Scripts: Yes, empty

    Scripts->>Scripts: Extract software from NFS zips
    Scripts->>hostPath: Write 15GB of Oracle binaries
    Scripts->>Scripts: Set GI_SW_UNZIPPED_FLAG=true

    Scripts->>Scripts: Skip check_home()<br/>(just unzipped)
    Scripts->>Scripts: Run crs_sw_install()
    Scripts->>Scripts: Run gridSetup.sh -silent

    Note over Scripts: Grid configuration creates:

    Scripts->>hostPath: Create cluvfy binary
    Scripts->>EtcOracle: Create /etc/oracle/olr.loc
    Scripts->>EtcOracle: Create /etc/oracle/scls_scr/

    Scripts->>Scripts: Run root.sh
    Scripts->>Scripts: Set CLUSTER_SETUP_FLAG=running

    Scripts->>Backup: backup_oracle_etc_files()
    EtcOracle-->>Backup: Copy to .etcoraclebackup/

    Note over Pod: Setup complete (~2 hours)
```

### Pod Restart (Subsequent Times)

```mermaid
sequenceDiagram
    participant Pod
    participant Scripts
    participant hostPath as hostPath (/u01)
    participant EtcOracle as /etc/oracle
    participant Backup as .etcoraclebackup

    Note over Pod: Container restarts<br/>(fresh container, same hostPath)

    Pod->>hostPath: Mount existing directory
    Scripts->>hostPath: Check: is home empty?
    hostPath-->>Scripts: No, has software!

    Scripts->>Scripts: Skip extraction<br/>"home directory is not empty"

    Scripts->>Scripts: set_banner() runs
    Scripts->>Scripts: GI_SW_UNZIPPED_FLAG not set

    Scripts->>hostPath: check_home(): cluvfy exists?
    hostPath-->>Scripts: Yes! /u01/app/19c/grid/bin/cluvfy

    Scripts->>Scripts: Run cluvfy comp software
    Scripts-->>Scripts: Validation passes, return 0
    Scripts->>Scripts: Set GI_HOME_INSTALLED_FLAG=true

    Scripts->>EtcOracle: check_gi_installed(): /etc/oracle exists?
    EtcOracle-->>Scripts: No (fresh container)

    Scripts->>Backup: Check .etcoraclebackup/ exists?
    Backup-->>Scripts: Yes! Has saved files

    Scripts->>Scripts: restore_gi_files()
    Backup-->>EtcOracle: Restore to /etc/oracle/

    Scripts->>Scripts: start_crs()
    Scripts->>Scripts: Set GI_HOME_CONFIGURED_FLAG=true

    Note over Scripts: setup() sees GI_HOME_CONFIGURED_FLAG

    Scripts->>Scripts: SKIP all installation!
    Scripts->>Scripts: Just backup_oracle_etc_files()

    Note over Pod: Startup complete (~5-10 minutes)
```

---

## Summary: What Gets Checked and Set

### Filesystem Checks

| Check | Location | Created During | Required For |
|-------|----------|----------------|--------------|
| cluvfy binary | `{GRID_HOME}/bin/cluvfy` | Grid Configuration | `check_home()` to pass |
| /etc/oracle dir | `/etc/oracle/` | Grid Configuration | Skip setup entirely |
| .etcoraclebackup | `{GRID_BASE}/.etcoraclebackup/` | After setup (backup) | Restore /etc/oracle |
| Home not empty | `{GRID_HOME}/` | Extraction | Skip extraction |

### Runtime Flags

| Flag | Triggers | Set By | Effect |
|------|----------|--------|--------|
| `GI_SW_UNZIPPED_FLAG` | Software extraction | `_setup_software()` | Skip `check_home()` |
| `GI_HOME_INSTALLED_FLAG` | `check_home()` = 0 | `set_banner()` | Informational |
| `GI_HOME_CONFIGURED_FLAG` | `check_gi_installed()` = True | `set_banner()` | **SKIP ALL SETUP** |
| `CLUSTER_SETUP_FLAG` | Cluster verified healthy | `setup()` | Mark complete |
| `COPY_GRID_SOFTWARE` | Staged zips exist | `_setup_software()` | Trigger extraction |

### The Key Skip Condition

```python
# In setup() - This is the ultimate skip check
if self.ocommon.check_key("GI_HOME_CONFIGURED_FLAG", self.ora_env_dict):
    # SKIP EVERYTHING!
    # Just run backup_oracle_etc_files() and exit
```

This flag is set when:
1. `check_home()` returns 0 (cluvfy exists and validates)
2. AND either:
   - `/etc/oracle/` exists, OR
   - `/etc/oracle/` was successfully restored from `.etcoraclebackup/`

---

## Why Pre-Built RU Images Don't Help

```mermaid
flowchart TB
    subgraph image["RU Image Contents"]
        I1["✅ /u01/app/19c/grid/ (software)"]
        I2["❌ /u01/app/19c/grid/bin/cluvfy (MISSING)"]
        I3["❌ /etc/oracle/ (MISSING)"]
    end

    subgraph checks["Detection Checks"]
        C1["check_home() looks for cluvfy"]
        C2["check_gi_installed() looks for /etc/oracle"]
    end

    subgraph result["Result"]
        R1["Both checks FAIL"]
        R2["Full installation triggered"]
        R3["RU image software UNUSED"]
    end

    I2 --> C1
    I3 --> C2
    C1 -->|"cluvfy not found"| R1
    C2 -->|"/etc/oracle not found"| R1
    R1 --> R2
    R2 --> R3

    style I2 fill:#FF6B6B
    style I3 fill:#FF6B6B
    style R1 fill:#FF6B6B
    style R3 fill:#FF6B6B
```

The `cluvfy` binary and `/etc/oracle` directory are **only created during Grid configuration** (running `gridSetup.sh`), not during software extraction. The pre-built RU image has never been configured, so these don't exist.

---

*Document Version: 1.0*
*Created: September 2026*
*Source: Analysis of Oracle RAC startup scripts from rac_ru:latest-19 image*
