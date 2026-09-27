# Oracle RAC Container Image Guide

This document clarifies the confusion around Oracle RAC container images, explaining the different image types, their purposes, and how they relate to the Oracle Database Operator deployment.

---

## KEY LEARNING - VERIFIED BY LOG ANALYSIS

```
┌─────────────────────────────────────────────────────────────────────────────┐
│            ⚠️  THE REAL STORY: REDUNDANT PATCHING OCCURRED  ⚠️              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  STEP 1: We verified the IMAGE has patches pre-applied:                     │
│  ─────────────────────────────────────────────────────                      │
│  $ podman run --rm --user oracle --entrypoint '' \                          │
│      container-registry.oracle.com/database/rac_ru:latest-19 \              │
│      /u01/app/19c/grid/OPatch/opatch lspatches                              │
│                                                                              │
│  IMAGE contains: 19.32.0.0.0 RU (patches 39526364, 39503034, 39472050...)   │
│                                                                              │
│  STEP 2: We checked what was STAGED on NFS:                                  │
│  ──────────────────────────────────────────                                 │
│  /export/stage/19c/19.29/RU/39467003/README.html shows:                     │
│  "GI Release Update 19.32.0.0.260721"                                       │
│                                                                              │
│  STAGED patches: ALSO 19.32.0.0.0 RU (same version!)                        │
│                                                                              │
│  STEP 3: We checked the deployment LOGS:                                     │
│  ────────────────────────────────────────                                   │
│  /tmp/orod/oracle_db_setup.log shows:                                        │
│                                                                              │
│  gridSetup.sh -applyRU "/mnt/stage/rupatch" ...                             │
│                                                                              │
│  The setup scripts STILL ran patching operations because we specified       │
│  ruPatchLocation in racdb.yaml!                                             │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  WHAT ACTUALLY HAPPENED:                                                     │
│                                                                              │
│  ┌────────────────────┐      ┌────────────────────┐                         │
│  │  IMAGE             │      │  NFS STAGING       │                         │
│  │  19.32.0.0.0 RU    │  ==  │  19.32.0.0.0 RU    │  SAME VERSION!          │
│  │  (pre-applied)     │      │  (patch 39467003)  │                         │
│  └────────────────────┘      └────────────────────┘                         │
│           │                           │                                      │
│           │                           │                                      │
│           ▼                           ▼                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Because ruPatchLocation was specified in racdb.yaml:               │    │
│  │  → Setup scripts called: gridSetup.sh -applyRU "/mnt/stage/rupatch" │    │
│  │  → Oracle analyzed and processed staged patches                     │    │
│  │  → Even though patches were same/already applied, this took HOURS   │    │
│  │  → REDUNDANT WORK!                                                   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  THE FIX FOR FASTER DEPLOYMENT:                                              │
│                                                                              │
│  With rac_ru images (pre-patched), OMIT these parameters:                   │
│                                                                              │
│  configParams:                                                               │
│    # ruPatchLocation: "/scratch/software/stage/19c/19.29/RU"  ← REMOVE!    │
│    # oPatchLocation: "/scratch/software/stage/19c/19.29/OPATCH" ← REMOVE!  │
│                                                                              │
│  This prevents gridSetup.sh from running with -applyRU flag,                │
│  saving HOURS of redundant patching operations.                             │
│                                                                              │
│  Only specify ruPatchLocation if you need patches NEWER than the image!    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Table of Contents

1. [Image Naming Confusion](#1-image-naming-confusion)
2. [Available Image Types](#2-available-image-types)
3. [Oracle Container Registry Images](#3-oracle-container-registry-images)
4. [Image Selection Decision Tree](#4-image-selection-decision-tree)
5. [What's Inside Each Image](#5-whats-inside-each-image)
6. [Our Deployment Choice](#6-our-deployment-choice)
7. [Software Staging vs Pre-built Images](#7-software-staging-vs-pre-built-images)
8. [Common Confusion Points](#8-common-confusion-points)
9. [Image Pull and Verification](#9-image-pull-and-verification)

---

## 1. Image Naming Confusion

There are multiple names used for Oracle RAC container images, which creates confusion:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    IMAGE NAMING CONFUSION EXPLAINED                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ORACLE CONTAINER REGISTRY NAMES:                                            │
│  ─────────────────────────────────                                          │
│  container-registry.oracle.com/database/rac:latest        → 23ai (newest)   │
│  container-registry.oracle.com/database/rac_ru:latest     → 21c with RU     │
│  container-registry.oracle.com/database/rac_ru:latest-19  → 19c with RU     │
│                                                                              │
│  LOCAL/DOCUMENTATION NAMES:                                                  │
│  ──────────────────────────                                                 │
│  localhost/oracle/database-rac:19.3.0      → Same as rac_ru:latest-19       │
│  localhost/oracle/database-rac:21.3.0      → Same as rac_ru:latest          │
│  localhost/oracle/database-rac:23.26ai     → Same as rac:latest             │
│                                                                              │
│  THE CONFUSION:                                                              │
│  ──────────────                                                             │
│  • "rac" vs "rac_ru" - different repositories!                              │
│  • "database-rac" - local naming convention, not a registry path            │
│  • "latest" vs "latest-19" - different database versions!                   │
│  • "slim" images - NOT available on Oracle Container Registry               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Clarification

| Registry Name | Local Name Convention | Database Version | Notes |
|--------------|----------------------|------------------|-------|
| `rac:latest` | `database-rac:23.26ai` | 23ai (26c) | Newest, Oracle Linux 9 |
| `rac_ru:latest` | `database-rac:21.3.0` | 21c | Oracle Linux 8 |
| `rac_ru:latest-19` | `database-rac:19.3.0` | 19c | Oracle Linux 9, our choice |

---

## 2. Available Image Types

Oracle provides three types of RAC container images:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         RAC IMAGE TYPES                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  1. FULL IMAGE (rac / rac_ru)                                       │    │
│  │                                                                      │    │
│  │  Contents:                                                           │    │
│  │  • Oracle Linux base OS                                              │    │
│  │  • Grid Infrastructure binaries (pre-installed)                      │    │
│  │  • Oracle Database binaries (pre-installed)                          │    │
│  │  • Release Update patches (for rac_ru images)                        │    │
│  │  • Setup scripts (/opt/scripts/startup/*)                            │    │
│  │                                                                      │    │
│  │  Use when: Standard deployment, no customization needed              │    │
│  │  Available from: Oracle Container Registry ✅                        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  2. SLIM IMAGE                                                       │    │
│  │                                                                      │    │
│  │  Contents:                                                           │    │
│  │  • Oracle Linux base OS                                              │    │
│  │  • Setup scripts only                                                │    │
│  │  • NO Grid Infrastructure binaries                                   │    │
│  │  • NO Oracle Database binaries                                       │    │
│  │                                                                      │    │
│  │  Use when: Software staged externally (NFS), custom patching         │    │
│  │  Available from: Must build yourself ❌                              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  3. BASE IMAGE                                                       │    │
│  │                                                                      │    │
│  │  Contents:                                                           │    │
│  │  • Oracle Linux base OS                                              │    │
│  │  • Minimal setup for building custom images                          │    │
│  │                                                                      │    │
│  │  Use when: Building custom RAC images with specific patches          │    │
│  │  Available from: Must build yourself ❌                              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Oracle Container Registry Images

### 3.1 Available Tags

```bash
# 23ai (Latest - Oracle Linux 9)
container-registry.oracle.com/database/rac:latest
container-registry.oracle.com/database/rac:23.26ai

# 21c with Release Update (Oracle Linux 8)
container-registry.oracle.com/database/rac_ru:latest
container-registry.oracle.com/database/rac_ru:21.3.0

# 19c with Release Update (Oracle Linux 9) ← WE USED THIS
container-registry.oracle.com/database/rac_ru:latest-19
container-registry.oracle.com/database/rac_ru:19.3.0
```

### 3.2 Repository Differences

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    rac vs rac_ru REPOSITORIES                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  database/rac (no _ru suffix):                                               │
│  ─────────────────────────────                                              │
│  • Contains Oracle Database 23ai (Free or Enterprise)                       │
│  • Latest major version                                                      │
│  • May or may not have latest patches                                        │
│                                                                              │
│  database/rac_ru (with _ru suffix):                                          │
│  ──────────────────────────────────                                         │
│  • RU = Release Update                                                       │
│  • Contains quarterly Release Update patches                                 │
│  • For 19c and 21c versions                                                  │
│  • Recommended for production (patched)                                      │
│                                                                              │
│  Why the split?                                                              │
│  ──────────────                                                             │
│  • 23ai is new, uses "rac" repository                                        │
│  • 19c/21c are LTS releases, use "rac_ru" for patched versions              │
│  • Older "rac" images for 19c/21c were unpatched base releases              │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Image Selection Decision Tree

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      WHICH IMAGE SHOULD YOU USE?                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│                    Start Here                                                │
│                        │                                                     │
│                        ▼                                                     │
│              ┌─────────────────┐                                            │
│              │ Need 23ai/26c?  │                                            │
│              └────────┬────────┘                                            │
│                       │                                                      │
│         ┌─────────────┴─────────────┐                                       │
│         │ YES                       │ NO                                    │
│         ▼                           ▼                                        │
│  ┌──────────────┐         ┌─────────────────┐                               │
│  │ rac:latest   │         │ Need 19c or 21c?│                               │
│  │ (23.26ai)    │         └────────┬────────┘                               │
│  └──────────────┘                  │                                         │
│                      ┌─────────────┴─────────────┐                          │
│                      │ 19c                       │ 21c                      │
│                      ▼                           ▼                           │
│             ┌────────────────┐          ┌────────────────┐                  │
│             │ rac_ru:        │          │ rac_ru:latest  │                  │
│             │ latest-19      │          │ (21c)          │                  │
│             └───────┬────────┘          └────────────────┘                  │
│                     │                                                        │
│                     ▼                                                        │
│         ┌───────────────────────┐                                           │
│         │ Need custom patches   │                                           │
│         │ beyond what's in RU?  │                                           │
│         └───────────┬───────────┘                                           │
│                     │                                                        │
│       ┌─────────────┴─────────────┐                                         │
│       │ YES                       │ NO                                      │
│       ▼                           ▼                                          │
│  ┌──────────────────┐     ┌──────────────────┐                              │
│  │ Build SLIM image │     │ Use rac_ru:      │                              │
│  │ + NFS staging    │     │ latest-19        │  ← OUR CHOICE                │
│  └──────────────────┘     │ (pre-built)      │                              │
│                           └──────────────────┘                              │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. What's Inside Each Image

### 5.1 Full Image Contents (rac_ru:latest-19)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              rac_ru:latest-19 IMAGE CONTENTS (VERIFIED)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  /                                                                           │
│  ├── opt/                                                                    │
│  │   └── scripts/                                                            │
│  │       └── startup/                                                        │
│  │           ├── scripts/           ← Setup orchestration                   │
│  │           │   ├── main.py        ← Main entry point                      │
│  │           │   ├── setup_rac.py   ← RAC setup logic                       │
│  │           │   ├── grid_setup.py  ← Grid Infrastructure setup             │
│  │           │   └── db_setup.py    ← Database creation                     │
│  │           └── functions/         ← Helper functions                      │
│  │                                                                           │
│  ├── u01/                                                                    │
│  │   └── app/                                                                │
│  │       ├── 19c/                                                            │
│  │       │   └── grid/              ← Grid Infrastructure HOME              │
│  │       │       ├── bin/              (19.32.0.0.0 PRE-PATCHED ✅)         │
│  │       │       ├── lib/                                                    │
│  │       │       ├── OPatch/                                                 │
│  │       │       └── ...            ← ~12GB installed + patched             │
│  │       │                                                                   │
│  │       └── oracle/                                                         │
│  │           └── product/                                                    │
│  │               └── 19c/                                                    │
│  │                   └── dbhome_1/  ← Database HOME                         │
│  │                       ├── bin/      (19.32.0.0.0 PRE-PATCHED ✅)         │
│  │                       ├── lib/                                            │
│  │                       ├── OPatch/                                         │
│  │                       └── ...    ← ~12GB installed + patched             │
│  │                                                                           │
│  └── etc/                                                                    │
│      └── oraInst.loc               ← Oracle inventory location              │
│                                                                              │
│  IMAGE SIZE: ~17 GB (on disk), compressed ~6-8 GB                           │
│                                                                              │
│  ✅ VERIFIED: Both homes have 19.32 RU pre-applied in the image!            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Slim Image Contents (if you build it)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              SLIM IMAGE CONTENTS (Self-Built)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  /                                                                           │
│  ├── opt/                                                                    │
│  │   └── scripts/                                                            │
│  │       └── startup/                                                        │
│  │           ├── scripts/           ← Setup orchestration                   │
│  │           └── functions/         ← Helper functions                      │
│  │                                                                           │
│  ├── u01/                                                                    │
│  │   └── app/                       ← EMPTY! No software pre-installed     │
│  │                                                                           │
│  └── etc/                                                                    │
│      └── (minimal config)                                                    │
│                                                                              │
│  IMAGE SIZE: ~2-3 GB (compressed: ~800 MB)                                  │
│  PATCHES: None - you provide software via NFS staging                       │
│                                                                              │
│  REQUIRES:                                                                   │
│  • NFS mount with Grid Infrastructure ZIP                                    │
│  • NFS mount with Database ZIP                                               │
│  • NFS mount with OPatch ZIP                                                 │
│  • NFS mount with Release Update patches                                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Our Deployment Choice

### 6.1 What We Used

```yaml
# From racdb.yaml
image: container-registry.oracle.com/database/rac_ru:latest-19
imagePullPolicy: IfNotPresent
imagePullSecret: oracle-container-registry-secret
```

### 6.2 Why We Chose This

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY rac_ru:latest-19?                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ✅ REASONS FOR THIS CHOICE:                                                │
│                                                                              │
│  1. Pre-built image - No need to build our own                              │
│     • Available directly from Oracle Container Registry                      │
│     • Tested and certified by Oracle                                         │
│                                                                              │
│  2. Oracle Linux 9 base - Matches our worker nodes                          │
│     • Workers run Oracle Linux 9.8                                           │
│     • Avoids glibc compatibility issues                                      │
│                                                                              │
│  3. 19c Long-Term Support                                                    │
│     • Most widely deployed version                                           │
│     • Extended support until 2027+                                           │
│     • Best documentation and community support                               │
│                                                                              │
│  4. Fully pre-patched (19.32 RU)                                            │
│     • Grid + DB homes already installed AND patched                          │
│     • No runtime patching required                                           │
│     • Fastest deployment option                                              │
│                                                                              │
│  5. No NFS staging needed for patching                                       │
│     • Patches already in image                                               │
│     • Only need NFS if applying ADDITIONAL patches beyond 19.32             │
│                                                                              │
│  ❌ ALTERNATIVE CONSIDERED BUT REJECTED:                                    │
│                                                                              │
│  • Slim image: Would require building + staging all ZIPs + patching         │
│  • rac_ru:latest (21c): Oracle Linux 8, glibc mismatch                      │
│  • rac:latest (23ai): Too new, less documented                              │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Actual Image Details (Verified)

```bash
# What we pulled
$ podman pull container-registry.oracle.com/database/rac_ru:latest-19

# Verified by running image directly:
$ podman run --rm --user oracle --entrypoint '' \
    container-registry.oracle.com/database/rac_ru:latest-19 \
    /u01/app/19c/grid/OPatch/opatch lspatches

# Output confirms patches ARE pre-applied:
39526364;OCW RELEASE UPDATE 19.32.0.0.0
39503034;ACFS RELEASE UPDATE 19.32.0.0.0
39472050;Database Release Update : 19.32.0.0.260721
39107855;TOMCAT RELEASE UPDATE 19.0.0.0.0
39107825;DBWLM RELEASE UPDATE 19.0.0.0.0

# Image details:
Oracle Database Version: 19c (19.32.0.0.0 RU pre-applied)
Grid Infrastructure Version: 19c (19.32.0.0.0 RU pre-applied)
Base OS: Oracle Linux 9
Architecture: x86_64
Size: ~17 GB (crictl shows 16.8GB)
```

---

## 7. Software Staging vs Pre-built Images

### 7.1 Verified: Image IS Pre-Patched

**VERIFIED:** The `rac_ru:latest-19` image has binaries PRE-INSTALLED AND PRE-PATCHED!

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHAT'S ACTUALLY IN THE IMAGE (VERIFIED)                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  rac_ru:latest-19 contains:                                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  ✅ Grid Infrastructure binaries - PRE-INSTALLED                    │    │
│  │  ✅ Database binaries - PRE-INSTALLED                               │    │
│  │  ✅ OPatch utility - PRE-INSTALLED                                  │    │
│  │  ✅ 19.32 Release Update - PRE-APPLIED!                             │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  The "RU" in "rac_ru" means Release Update IS INCLUDED in the image.        │
│  Oracle updates these images quarterly with the latest RU.                   │
│                                                                              │
│  NO runtime patching occurs - patches are already in the image!             │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Our Configuration (CAUSED REDUNDANT PATCHING!)

```yaml
configParams:
  hostSwStageLocation: "/scratch/software/stage"
  gridSwZipFile: "LINUX.X64_193000_grid_home.zip"      # NOT used (pre-installed)
  dbSwZipFile: "LINUX.X64_193000_db_home.zip"          # NOT used (pre-installed)
  oPatchSwZipFile: "p6880880_190000_Linux-x86-64.zip"  # Potentially used
  ruPatchLocation: "/scratch/software/stage/19c/19.29/RU"   # ⚠️ CAUSED REDUNDANT PATCHING!
  oPatchLocation: "/scratch/software/stage/19c/19.29/OPATCH" # ⚠️ CAUSED REDUNDANT PATCHING!
```

**The Problem:** By specifying `ruPatchLocation`, we caused the setup scripts to run
`gridSetup.sh -applyRU` even though the image already had the same patches!

**The Fix:** With pre-patched `rac_ru` images, OMIT `ruPatchLocation` and `oPatchLocation`
unless you need patches NEWER than what's in the image.

### 7.3 How It Actually Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│               FULL IMAGE BEHAVIOR: WITH vs WITHOUT ruPatchLocation           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  WITH rac_ru IMAGE + ruPatchLocation SPECIFIED (OUR CASE - SLOW!):          │
│  ─────────────────────────────────────────────────────────────────          │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Image contains 19.32 patches pre-applied, BUT:                      │    │
│  │                                                                      │    │
│  │  Because ruPatchLocation was specified in racdb.yaml:               │    │
│  │  1. Setup scripts run: gridSetup.sh -applyRU "/mnt/stage/rupatch"   │    │
│  │  2. Oracle analyzes staged patches (even if same version!)          │    │
│  │  3. Oracle compares/verifies/re-applies patches                     │    │
│  │  4. THIS TAKES HOURS even when patches are already applied!         │    │
│  │  5. Then normal setup continues (root.sh, dbca, etc.)               │    │
│  │                                                                      │    │
│  │  Result: REDUNDANT PATCHING WORK = SLOW DEPLOYMENT                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  WITH rac_ru IMAGE + ruPatchLocation OMITTED (OPTIMAL - FAST!):             │
│  ──────────────────────────────────────────────────────────────             │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Image contains 19.32 patches pre-applied:                           │    │
│  │                                                                      │    │
│  │  Without ruPatchLocation specified:                                  │    │
│  │  1. Setup scripts run: gridSetup.sh (NO -applyRU flag!)             │    │
│  │  2. No patching operations occur                                     │    │
│  │  3. Grid Infrastructure configured directly                          │    │
│  │  4. ASM disk groups created                                         │    │
│  │  5. Database created with dbca                                       │    │
│  │                                                                      │    │
│  │  Result: NO REDUNDANT PATCHING = FAST DEPLOYMENT                    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  WITH SLIM IMAGE (requires all staging):                                     │
│  ────────────────────────────────────────                                   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Image contains setup scripts only, NO binaries:                     │    │
│  │                                                                      │    │
│  │  1. gridSwZipFile extracted to gridHome (~12GB)                     │    │
│  │  2. dbSwZipFile extracted to dbHome (~12GB)                         │    │
│  │  3. OPatch updated from oPatchSwZipFile                             │    │
│  │  4. RU patches applied from ruPatchLocation (required!)             │    │
│  │  5. Grid/DB configured and started                                   │    │
│  │                                                                      │    │
│  │  Result: EXTRACTION + PATCHING + SETUP = SLOWEST                    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.4 What Our Staged Software Was Used For

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    STAGED SOFTWARE USAGE SUMMARY                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  NFS Mount: ocne-op:/export/stage → /scratch/software/stage                 │
│  Staged RU: 39467003 = GI Release Update 19.32.0.0.260721                   │
│  Image RU:  39472050 = Database Release Update 19.32.0.0.260721             │
│                                                                              │
│  SAME VERSION! Both are 19.32.0.0.0 RU                                       │
│                                                                              │
│  ┌────────────────────────────────────┬──────────┬────────────────────────┐ │
│  │ Staged Component                   │ Used?    │ What Happened          │ │
│  ├────────────────────────────────────┼──────────┼────────────────────────┤ │
│  │ LINUX.X64_193000_grid_home.zip     │ NO       │ Pre-installed in image │ │
│  │ LINUX.X64_193000_db_home.zip       │ NO       │ Pre-installed in image │ │
│  │ p6880880_190000_Linux-x86-64.zip   │ YES      │ OPatch may be updated  │ │
│  │ 19.32 RU patches (39467003)        │ YES*     │ *Redundantly processed │ │
│  └────────────────────────────────────┴──────────┴────────────────────────┘ │
│                                                                              │
│  *REDUNDANT PROCESSING: Because ruPatchLocation was specified, the setup   │
│   scripts ran "gridSetup.sh -applyRU" which processed the staged patches   │
│   even though the image already had the same 19.32 patches applied!        │
│                                                                              │
│  This redundant patching operation took HOURS and was unnecessary.          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.5 What Actually Took Time During Deployment

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    DEPLOYMENT TIME BREAKDOWN (OUR CASE)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Evidence from logs (/tmp/orod/oracle_db_setup.log):                         │
│  ────────────────────────────────────────────────────                       │
│  gridSetup.sh -applyRU "/mnt/stage/rupatch" ...                             │
│                                                                              │
│  TIME SPENT (in our deployment):                                             │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  1. REDUNDANT PATCHING (gridSetup.sh -applyRU)         ~2-3 hours   │    │
│  │     • Oracle analyzed staged 19.32 patches                          │    │
│  │     • Compared with pre-applied 19.32 in image                      │    │
│  │     • Processed/verified/possibly re-applied                        │    │
│  │     • THIS WAS UNNECESSARY!                                          │    │
│  │                                                                      │    │
│  │  2. Grid Infrastructure Setup                          ~20-40 min   │    │
│  │     • root.sh (node1) - Starts cluster services                     │    │
│  │     • root.sh (node2) - Joins cluster                               │    │
│  │     • ASM disk group creation                                       │    │
│  │                                                                      │    │
│  │  3. Database Creation (dbca)                           ~30-60 min   │    │
│  │     • Creates datafiles, control files, redo logs                   │    │
│  │     • Runs catalog/catproc scripts                                  │    │
│  │     • Creates PDB (ORCLPDB)                                         │    │
│  │     • Configures listeners and services                             │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  HOW TO AVOID REDUNDANT PATCHING TIME:                                       │
│  ──────────────────────────────────────                                     │
│  With rac_ru images, OMIT these from racdb.yaml:                            │
│  • ruPatchLocation                                                           │
│  • oPatchLocation                                                            │
│                                                                              │
│  This prevents gridSetup.sh from using -applyRU flag.                       │
│  Expected time savings: 2-3 hours!                                           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. Common Confusion Points

### 8.1 Confusion #1: "latest" Tag

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CONFUSION: What does "latest" mean?                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  rac:latest          → 23ai (23.26ai) - NOT 19c or 21c!                     │
│  rac_ru:latest       → 21c (21.3.0)   - NOT 19c!                            │
│  rac_ru:latest-19    → 19c (19.3.0)   - This is 19c                         │
│                                                                              │
│  "latest" without version suffix = newest major version in that repo        │
│  "latest-19" = latest patch level of 19c                                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 Confusion #2: Image Name vs Registry Path

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CONFUSION: Why do docs show "oracle/database-rac" but registry has         │
│             "database/rac_ru"?                                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Oracle Container Registry:                                                  │
│  container-registry.oracle.com/database/rac_ru:latest-19                    │
│                               ^^^^^^^^^^^^^^^^                              │
│                               This is the registry path                      │
│                                                                              │
│  Local naming convention (after pulling/building):                           │
│  localhost/oracle/database-rac:19.3.0                                       │
│            ^^^^^^^^^^^^^^^^^^^^^                                            │
│            This is how you RETAG it locally                                  │
│                                                                              │
│  They are the SAME image, just different naming conventions!                │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.3 Confusion #3: Slim Image Availability

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CONFUSION: Where is the slim image in Oracle Container Registry?           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ANSWER: It's NOT there!                                                    │
│                                                                              │
│  • Oracle Container Registry only has FULL images                           │
│  • Slim images must be built locally using:                                 │
│    ./buildContainerImage.sh -v 19.3.0 --build-arg SLIMMING=true            │
│                                                                              │
│  • lab.env reference to "RAC_SLIM_IMAGE" was for a locally-built image     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.4 Confusion #4: ruPatchLocation with Pre-Patched Images

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CONFUSION: Should I specify ruPatchLocation with rac_ru images?            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  SHORT ANSWER: NO! (unless you need patches NEWER than the image)           │
│                                                                              │
│  WHAT HAPPENS IF YOU SPECIFY ruPatchLocation:                               │
│  ─────────────────────────────────────────────                              │
│  1. Setup scripts detect ruPatchLocation is set                             │
│  2. gridSetup.sh is called with -applyRU flag                              │
│  3. Oracle processes the staged patches                                     │
│  4. Even if patches are same version, this takes HOURS                      │
│  5. Result: Redundant work, slow deployment                                 │
│                                                                              │
│  EVIDENCE FROM OUR DEPLOYMENT:                                               │
│  ─────────────────────────────                                              │
│  Log: /tmp/orod/oracle_db_setup.log                                          │
│  Command: gridSetup.sh -applyRU "/mnt/stage/rupatch" ...                    │
│                                                                              │
│  Image had: 19.32.0.0.0 RU                                                  │
│  We staged: 19.32.0.0.0 RU (same!)                                          │
│  Result: Hours of redundant patching operations                             │
│                                                                              │
│  RECOMMENDATION:                                                             │
│  ───────────────                                                            │
│  1. Check image patch level BEFORE deployment:                              │
│     $ podman run --rm --user oracle --entrypoint '' \                       │
│         container-registry.oracle.com/database/rac_ru:latest-19 \           │
│         /u01/app/19c/grid/OPatch/opatch lspatches                           │
│                                                                              │
│  2. If image has the patches you need, OMIT ruPatchLocation                 │
│                                                                              │
│  3. Only specify ruPatchLocation if you need patches NEWER than image       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. Image Pull and Verification

### 9.1 Pull Commands

```bash
# Login to Oracle Container Registry (required)
podman login container-registry.oracle.com

# Pull the image
podman pull container-registry.oracle.com/database/rac_ru:latest-19

# Verify the image
podman images | grep rac_ru
```

### 9.2 Kubernetes Secret for Image Pull

```bash
# Create the pull secret (we did this)
kubectl create secret docker-registry oracle-container-registry-secret \
  --docker-server=container-registry.oracle.com \
  --docker-username=<oracle-sso-email> \
  --docker-password=<oracle-sso-password> \
  -n rac
```

### 9.3 Verify Image on Nodes

```bash
# On worker nodes, check if image was pulled
crictl images | grep rac_ru

# Expected output:
container-registry.oracle.com/database/rac_ru   latest-19   abc123def456   25.3GB
```

---

## Quick Reference

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         QUICK REFERENCE (LESSONS LEARNED)                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  OUR DEPLOYMENT:                                                             │
│  Image: container-registry.oracle.com/database/rac_ru:latest-19             │
│  Image Patch Level: 19.32.0.0.0 RU (verified by opatch lspatches)           │
│  Staged Patch Level: 19.32.0.0.0 RU (same version - redundant!)             │
│                                                                              │
│  WHAT HAPPENED:                                                              │
│  ┌────────────────────────────┬───────────┬──────────────────────┐          │
│  │ Component                  │ In Image? │ What We Did          │          │
│  ├────────────────────────────┼───────────┼──────────────────────┤          │
│  │ Grid Infrastructure        │ YES       │ N/A                  │          │
│  │ Database Home              │ YES       │ N/A                  │          │
│  │ 19.32 RU patches           │ YES       │ Staged same version! │          │
│  │ ruPatchLocation specified  │ N/A       │ ⚠️ CAUSED REDUNDANT  │          │
│  │                            │           │    PATCHING (hours!) │          │
│  └────────────────────────────┴───────────┴──────────────────────┘          │
│                                                                              │
│  ⚠️  KEY LESSON LEARNED:                                                    │
│  ───────────────────────                                                    │
│  With rac_ru images (pre-patched), do NOT specify ruPatchLocation           │
│  unless you need patches NEWER than what's in the image!                    │
│                                                                              │
│  Specifying ruPatchLocation causes gridSetup.sh to run with -applyRU        │
│  flag, which processes patches even if already applied = WASTED HOURS!      │
│                                                                              │
│  OPTIMAL racdb.yaml FOR rac_ru IMAGES:                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  configParams:                                                       │    │
│  │    gridHome: "/u01/app/19c/grid"                                     │    │
│  │    dbHome: "/u01/app/oracle/product/19c/dbhome_1"                    │    │
│  │    # ruPatchLocation: ...    ← OMIT THIS!                           │    │
│  │    # oPatchLocation: ...     ← OMIT THIS!                           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  HOW TO VERIFY IMAGE PATCH LEVEL BEFORE DEPLOYMENT:                          │
│  $ podman run --rm --user oracle --entrypoint '' \                          │
│      container-registry.oracle.com/database/rac_ru:latest-19 \              │
│      /u01/app/19c/grid/OPatch/opatch lspatches                              │
│                                                                              │
│  DOCUMENTATION:                                                              │
│  • GitHub: github.com/oracle/docker-images/.../OracleRealApplicationClusters│
│  • Oracle Docs: docs.oracle.com/en/database/oracle/oracle-database/19/      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

---

## 10. Optimized Configuration for Future Deployments

### 10.1 Lessons Learned from Round 1

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    ROUND 1 vs ROUND 2 COMPARISON                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ROUND 1 (What we did - SLOW):                                               │
│  ─────────────────────────────                                              │
│  • Used rac_ru:latest-19 image (has 19.32 pre-applied)                      │
│  • Staged 19.32 patches on NFS (same version as image!)                     │
│  • Specified ruPatchLocation in racdb.yaml                                  │
│  • Result: gridSetup.sh ran with -applyRU flag                             │
│  • Wasted ~2-3 hours on redundant patching                                  │
│                                                                              │
│  ROUND 2 (Optimized - FAST):                                                 │
│  ─────────────────────────────                                              │
│  • Use rac_ru:latest-19 image (has 19.32 pre-applied)                       │
│  • OMIT ruPatchLocation from racdb.yaml                                     │
│  • OMIT oPatchLocation from racdb.yaml                                      │
│  • Result: gridSetup.sh runs WITHOUT -applyRU flag                         │
│  • Save ~2-3 hours of deployment time!                                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 10.2 Optimized racdb.yaml for Pre-Patched Images

```yaml
---
apiVersion: database.oracle.com/v4
kind: RacDatabase
metadata:
  name: racdb01
  namespace: rac
spec:
  instanceDetails:
    nodeCount: 2
    racHostSwLocation: /scratch/rac/cluster01
    racNodeName: racnode
    baseOnsTargetPort: 30200
    baseLsnrTargetPort: 31522
    privateIPDetails:
      - name: rac-priv1
        interface: ens1
      - name: rac-priv2
        interface: ens2
    workerNodeSelector:
      raccluster: raccluster01

  # Pre-patched image - no runtime patching needed
  image: container-registry.oracle.com/database/rac_ru:latest-19
  imagePullPolicy: IfNotPresent
  imagePullSecret: oracle-container-registry-secret

  configParams:
    gridHome: "/u01/app/19c/grid"
    gridBase: "/u01/app/grid"
    dbHome: "/u01/app/oracle/product/19c/dbhome_1"
    dbBase: "/u01/app/oracle"
    inventory: "/u01/app/oraInventory"
    sgaSize: "8G"
    pgaSize: "2G"
    processes: 1000
    cpuCount: 4
    dbName: "RACDB"
    pdbName: "RACPDB"
    dbCharSet: "AL32UTF8"

    # ============================================================
    # OPTIMIZED: OMIT THESE PARAMETERS FOR PRE-PATCHED IMAGES!
    # ============================================================
    # The rac_ru:latest-19 image already has 19.32 RU applied.
    # Specifying these causes redundant patching (wastes hours).
    #
    # ONLY uncomment if you need patches NEWER than the image:
    # ruPatchLocation: "/scratch/software/stage/19c/19.33/RU"
    # oPatchLocation: "/scratch/software/stage/19c/19.33/OPATCH"
    # ============================================================

  asmDiskGroupDetails:
    - name: DATA
      redundancy: EXTERNAL
      type: CRSDG
      disks:
        - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0001
        - /dev/disk/by-id/ata-VBOX_HARDDISK_asmdisk0002

  # ... rest of configuration unchanged ...
```

### 10.3 Pre-Deployment Checklist

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PRE-DEPLOYMENT CHECKLIST                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Before deploying RAC with rac_ru images:                                    │
│                                                                              │
│  □ Step 1: Check image patch level                                          │
│    ┌─────────────────────────────────────────────────────────────────────┐  │
│    │ podman run --rm --user oracle --entrypoint '' \                     │  │
│    │   container-registry.oracle.com/database/rac_ru:latest-19 \         │  │
│    │   /u01/app/19c/grid/OPatch/opatch lspatches                         │  │
│    └─────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  □ Step 2: Determine if you need additional patches                         │
│    • If image has required RU (e.g., 19.32) → OMIT ruPatchLocation         │
│    • If you need newer RU (e.g., 19.33) → Stage and specify ruPatchLocation│
│                                                                              │
│  □ Step 3: Update racdb.yaml accordingly                                    │
│    • For pre-patched image: Remove/comment ruPatchLocation & oPatchLocation│
│    • For additional patches: Specify ruPatchLocation with NEWER patches    │
│                                                                              │
│  □ Step 4: Deploy                                                            │
│    • kubectl apply -f racdb.yaml                                            │
│                                                                              │
│  Expected deployment time (without redundant patching):                      │
│  • Grid Infrastructure setup: ~20-40 minutes                                │
│  • Database creation (dbca): ~30-60 minutes                                 │
│  • Total: ~1-2 hours (vs 4-5 hours with redundant patching)                │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 10.4 When TO Specify ruPatchLocation

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHEN TO USE ruPatchLocation                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ✅ USE ruPatchLocation when:                                               │
│  ───────────────────────────                                                │
│  • Image has 19.32, you need 19.33 (newer RU)                               │
│  • You need one-off patches not in the RU                                   │
│  • You're using a SLIM image (no patches pre-applied)                       │
│  • Security policy requires specific patch versions                         │
│                                                                              │
│  ❌ DO NOT USE ruPatchLocation when:                                        │
│  ─────────────────────────────────────                                      │
│  • Image already has the RU you need                                        │
│  • You staged the SAME version as the image (our mistake!)                  │
│  • You want fastest deployment time                                         │
│                                                                              │
│  EXAMPLE SCENARIOS:                                                          │
│  ──────────────────                                                         │
│                                                                              │
│  Scenario 1: Image has 19.32, you need 19.32                                │
│  → OMIT ruPatchLocation (image is sufficient)                               │
│                                                                              │
│  Scenario 2: Image has 19.32, you need 19.33                                │
│  → Stage 19.33 patches, SPECIFY ruPatchLocation                             │
│                                                                              │
│  Scenario 3: Using slim image (no patches)                                  │
│  → Stage required RU, SPECIFY ruPatchLocation                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Sources

- [Oracle RAC Docker Images GitHub](https://github.com/oracle/docker-images/blob/main/OracleDatabase/RAC/OracleRealApplicationClusters/README.md)
- [Oracle RAC Container Image Documentation](https://github.com/oracle/docker-images/blob/main/OracleDatabase/RAC/OracleRealApplicationClusters/docs/rac-container/racimage/README.md)
- [Oracle Container Registry](https://container-registry.oracle.com)

---

*Document created: Oracle RAC Container Image Guide - September 2026*
*Updated with Round 1 lessons learned and Round 2 optimization recommendations*
