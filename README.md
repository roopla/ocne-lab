# OCNE 1.9 + Oracle Database Operator Lab

**Author:** Alpoor Pradeep Reddy
**AI Assistant:** Claude Opus 4.5 (Anthropic) via [Claude Code](https://claude.ai/claude-code)

## Overview

This repository contains comprehensive documentation, scripts, and implementation guides for building and operating an Oracle Cloud Native Environment (OCNE) 1.9 cluster with the Oracle Database Operator. The lab environment runs on Oracle VirtualBox and demonstrates enterprise-grade Oracle database deployment patterns on Kubernetes.

### Purpose and Objectives

This lab serves a dual purpose:

1. **Learning and Skill Development:** Provides hands-on experience with Oracle's cloud-native database technologies, including Kubernetes orchestration, Oracle Database Operator lifecycle management, Data Guard configuration, ASM storage, and Oracle Restart/RAC architectures. The step-by-step walkthroughs document real-world troubleshooting scenarios and solutions encountered during implementation.

2. **Production-Ready Reference Architecture:** The configurations, patterns, and procedures documented here are designed to be adaptable for enterprise deployments. The lab validates deployment procedures, documents failure modes and their resolutions, and establishes operational runbooks that can be translated to production environments with appropriate scaling and security hardening.

### Architecture Summary

The lab consists of a 4-VM cluster running on VirtualBox:

| VM | Role | Resources |
|---|---|---|
| ocne-op | OLCNE Operator node, NFS server | 2 vCPU, 4 GB RAM |
| ocne-cp1 | Kubernetes Control Plane | 4 vCPU, 6 GB RAM |
| ocne-w1 | Worker node (database workloads) | 8 vCPU, 20 GB RAM |
| ocne-w2 | Worker node (database workloads) | 8 vCPU, 20 GB RAM |

### Implementation Phases

| Phase | Description | Status |
|---|---|---|
| 0-6 | Infrastructure setup: VMs, networking, storage, OCNE cluster, operator installation | Complete |
| A | SingleInstanceDatabase + Data Guard with automated failover | Complete |
| B | Oracle Restart with ASM storage on block devices | Complete |
| C | Real Application Clusters (RAC) with shared storage | Planned |

### Key Technologies Demonstrated

- **Oracle Cloud Native Environment (OCNE) 1.9** - Enterprise Kubernetes distribution
- **Oracle Database Operator** - Kubernetes operator for Oracle database lifecycle management
- **Oracle Data Guard** - High availability and disaster recovery
- **Oracle ASM (Automatic Storage Management)** - Database storage virtualization
- **Oracle Restart** - Single-instance high availability
- **Multus CNI** - Multiple network interface support for RAC interconnect
- **cert-manager** - TLS certificate management for operator webhooks

### Documentation Structure

| Document | Description |
|---|---|
| `runbook.md` | Master runbook with Phases 0-6 (infrastructure setup) |
| `complete-setup-guide.md` | Consolidated end-to-end setup guide with cleanup procedures |
| `phase-a-sidb-dataguard-setup.md` | Phase A implementation walkthrough with lessons learned |
| `phase-b-oracle-restart-asm-setup.md` | Phase B implementation walkthrough with lessons learned |
| `architecture-diagrams.md` | Infrastructure and component architecture diagrams |
| `troubleshooting-notes.md` | Common issues and resolutions |

### Enterprise Applicability

The patterns and procedures documented in this lab are directly applicable to enterprise Oracle database deployments on Kubernetes:

- **Database-as-a-Service (DBaaS):** The Oracle Database Operator enables self-service database provisioning with standardized configurations, making it suitable for internal DBaaS platforms.

- **Hybrid Cloud Deployments:** The same operator and configurations work across on-premises Kubernetes clusters, Oracle Cloud Infrastructure (OCI), and other cloud providers, enabling consistent database management across hybrid environments.

- **DevOps Integration:** The declarative Custom Resource (CR) approach integrates naturally with GitOps workflows, CI/CD pipelines, and infrastructure-as-code practices.

- **High Availability Patterns:** The Data Guard and RAC configurations demonstrate production-grade HA patterns that meet enterprise RTO/RPO requirements.

- **Storage Flexibility:** The lab demonstrates both NFS-based storage (Phase A) and block storage with ASM (Phase B/C), covering the primary storage patterns used in enterprise deployments.

### Prerequisites for Production Adaptation

When translating this lab to production environments, consider:

- Network security hardening (firewall rules, network policies, mTLS)
- Storage performance and redundancy requirements
- Backup and recovery procedures
- Monitoring and alerting integration
- RBAC and security context constraints
- Resource quotas and limit ranges
- Multi-tenancy considerations

### AI-Assisted Development

This lab was developed with the assistance of **Claude Opus 4.5**, Anthropic's most capable AI model, accessed through **Claude Code** - Anthropic's official CLI tool for software engineering tasks.

The AI assistant contributed to:

- **Implementation Execution:** Running commands across Windows host and Linux VMs via SSH, managing VirtualBox VMs, and executing Kubernetes operations
- **Troubleshooting:** Diagnosing and resolving issues such as glibc 2.34+ compatibility with Oracle 19c, DBCA failures in containerized environments, RBAC permission issues, and kernel parameter tuning
- **Documentation:** Creating comprehensive walkthroughs, architecture diagrams, and cleanup procedures based on actual implementation experience
- **Code Review:** Analyzing Oracle Database Operator configurations, Custom Resources, and deployment manifests

This demonstrates the effectiveness of AI-assisted infrastructure development for complex enterprise software deployments, where the AI handles mechanical execution while the human provides domain expertise and decision-making for critical operations.

### References and Resources

#### GitHub Repositories

| Repository | Purpose |
|------------|---------|
| [oracle/oracle-database-operator](https://github.com/oracle/oracle-database-operator) | Oracle Database Operator for Kubernetes - core operator used for SIDB, Data Guard, Oracle Restart, and RAC deployments |
| [oracle/docker-images](https://github.com/oracle/docker-images) | Oracle Docker/Container images - includes RAC container image build scripts (`OracleDatabase/RAC/OracleRealApplicationClusters`) |
| [cert-manager/cert-manager](https://github.com/cert-manager/cert-manager) | TLS certificate management for Kubernetes - required for operator webhooks |
| [rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner) | Dynamic local storage provisioner for Kubernetes |

#### Oracle Container Registry

| Image | Usage |
|-------|-------|
| `container-registry.oracle.com/database/enterprise:19.3.0.0` | Oracle Database Enterprise Edition - used for Phase A (SIDB + Data Guard) |
| `container-registry.oracle.com/database/rac:19.3.0` | Oracle RAC Database - used for Phase C |
| `container-registry.oracle.com/os/oraclelinux:9` | Base image for custom builds |

#### Oracle Documentation (My Oracle Support)

| Doc ID | Title |
|--------|-------|
| 2965269.1 | Oracle RAC on Podman/Kubernetes - Prerequisites and Best Practices |
| 2915366.2 | Building Gold Images for Oracle Grid Infrastructure and Database |
| 2805794.1 | Oracle Database Operator for Kubernetes Documentation |
| 1587357.1 | Using NFS with Oracle Database |

#### Oracle Technology Network Downloads

| Software | Version | File |
|----------|---------|------|
| Grid Infrastructure | 19.3.0 | `LINUX.X64_193000_grid_home.zip` |
| Database | 19.3.0 | `LINUX.X64_193000_db_home.zip` |
| GI Release Update 19.28 | Patch 37957391 | From MOS |
| OPatch | Latest | Patch 6880880 |

#### Official Documentation

- [Oracle Cloud Native Environment 1.9 Documentation](https://docs.oracle.com/en/operating-systems/olcne/)
- [Oracle Database Operator for Kubernetes](https://github.com/oracle/oracle-database-operator/blob/main/docs/README.md)
- [Oracle Data Guard Concepts and Administration](https://docs.oracle.com/en/database/oracle/oracle-database/19/sbydb/)
- [Oracle ASM Administrator's Guide](https://docs.oracle.com/en/database/oracle/oracle-database/19/ostmg/)
- [Oracle Real Application Clusters Administration Guide](https://docs.oracle.com/en/database/oracle/oracle-database/19/racad/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [cert-manager Documentation](https://cert-manager.io/docs/)

#### Tools Used

| Tool | Purpose |
|------|---------|
| [Oracle VirtualBox](https://www.virtualbox.org/) | VM hypervisor for lab environment |
| [Claude Code](https://claude.ai/claude-code) | AI-assisted development CLI tool |
| [kubectl](https://kubernetes.io/docs/reference/kubectl/) | Kubernetes command-line interface |
| [olcnectl](https://docs.oracle.com/en/operating-systems/olcne/) | OCNE cluster management CLI |

---

# Using Claude Code to build this lab

## 1. Install Claude Code on the Windows host

**Do not use WSL.** Phase 0 of the runbook disables WSL2, Hyper-V and Memory Integrity so
that VirtualBox runs on its own hypervisor. Installing Claude Code under WSL would put you
in the position of needing the thing you just turned off.

Use the native Windows installer, which is self-contained and needs no Node.js:

```powershell
irm https://claude.ai/install.ps1 | iex
```

Then verify:

```powershell
claude doctor
```

Git for Windows is recommended so Claude Code can use the Bash tool. Without it, Claude Code
falls back to PowerShell as the shell. Since this lab mixes PowerShell (`VBoxManage`) with
Bash-over-SSH (the nodes), installing Git for Windows is worth it:

```powershell
winget install -e --id Git.Git
```

A paid Claude plan or API credits are required; Claude Code is not on the free tier.

Docs: https://docs.claude.com/en/docs/claude-code/setup

## 2. Set up this folder

Put this folder somewhere outside `D:\VMs` so a VM rebuild never touches it, for example
`C:\lab\ocne-lab`. It should contain:

```
ocne-lab/
  CLAUDE.md          <- operating rules; Claude Code reads this automatically
  lab.env            <- all environment-specific values, in one place
  runbook.md         <- the build instructions (export from the Claude doc)
  scripts/
    check-gate.sh    <- read-only phase gate verification
  notes/             <- create this; put your own observations here
```

**Export `runbook.md`** from the runbook doc in Claude (the artifact's export/download
option, Markdown format) and save it into this folder. Claude Code needs it on disk;
it cannot see the doc otherwise.

**Edit `lab.env`** before you start. Every value marked `CHANGE ME` must match your actual
setup, in particular `BRIDGE_ADAPTER`, `LAN_SUBNET`, `LAN_GATEWAY` and the four node IPs.

## 3. Set up SSH from Windows to the nodes

Claude Code drives the VMs over SSH. After phase 3, copy the key so logins are passwordless
from the host, not just from `ocne-op`:

```powershell
# generate a host key if you do not have one
ssh-keygen -t ed25519 -f $HOME\.ssh\id_ed25519 -N '""'

# push it to each node (enter the root password once per node)
foreach ($h in @("ocne-op","ocne-cp1","ocne-w1","ocne-w2")) {
  type $HOME\.ssh\id_ed25519.pub | ssh root@$h "mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"
}
```

Also add the four nodes to `C:\Windows\System32\drivers\etc\hosts` (see runbook step 3.5),
or SSH by name will not resolve.

## 4. Run it

```powershell
cd C:\lab\ocne-lab
claude
```

Then work phase by phase. Useful opening prompts:

- `Read runbook.md and lab.env. Summarize phase 0 and tell me what you need from me before starting.`
- `Run phase 3. Stop at the gate and show me the verification output.`
- `./scripts/check-gate.sh 5` — or ask Claude Code to run it and interpret the failures.
- `Phase 5 gate failed on ocne-w2 INTERNAL-IP. Diagnose it.`

Ask for one phase at a time. The runbook's gates exist because a failure carried forward
gets much more expensive to find three phases later.

## 5. Things to keep Claude Code away from

`CLAUDE.md` already states these, but they are worth knowing yourself:

- The shared ASM disks (`/dev/sdc`, `/dev/sdd`, `/dev/sde` on the workers) must stay raw.
  VirtualBox provides no write locking on them; a stray `mkfs` corrupts both workers at once.
- Snapshots and rollbacks are your call, not Claude Code's.
- `olcnectl provision` and any database provisioning are long-running. If a command appears
  to hang, check the node before killing it.

## 6. A note on scope

Claude Code is good at the mechanical parts of this: running the command sequences, reading
logs, diagnosing why a pod is Pending, comparing what the runbook says against what the
machine reports. It is less good at deciding whether a deviation matters. When the runbook
says a step is a known-tricky area, read that section yourself before accepting a workaround.
