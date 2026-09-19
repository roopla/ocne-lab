# OCNE 1.9 + Oracle Database Operator home lab

You are helping build a 4-VM Oracle Cloud Native Environment 1.9 cluster on VirtualBox,
then exercising the Oracle Database Operator on it. The authoritative build instructions
are in `runbook.md` in this folder. Read it before acting.

## Your operating rules

1. **`runbook.md` is the spec.** Follow it phase by phase. If a command in it fails or looks
   wrong for what you actually observe on the machine, say so and propose a fix. Do not
   silently substitute a different approach.
2. **One phase at a time.** Stop at each `Gate:` line, run the verification commands, and
   report the result before continuing. Never continue past a failed gate.
3. **Ask before anything destructive.** Specifically: `dd`, `mkfs`, `pvcreate`, `vgremove`,
   `VBoxManage unregistervm`, `VBoxManage closemedium`, deleting VDIs, `kubectl delete` on
   anything you did not create in this session, rebooting a node, or editing `/etc/fstab`.
4. **Never touch `/dev/sdc`, `/dev/sdd`, `/dev/sde` on the workers** without explicit
   confirmation. Those are the shared ASM disks. No partition table, no filesystem, no LVM.
   VirtualBox gives them no write locking; a mistake here corrupts both nodes at once.
5. **Long-running commands.** `olcnectl provision` takes 10-20 minutes and database
   provisioning takes hours. Run them with generous timeouts and stream output rather than
   polling. Do not assume a silent command has hung.
6. **Report what you actually saw.** Paste the real output of verification commands. Do not
   summarize a check as passing unless you ran it and read the result.

## Environment

Read `lab.env` for hostnames, IPs, paths and VM names. Update it if the real values differ;
everything else should read from it rather than hard-coding.

Two execution contexts:

- **Windows host** (this machine): PowerShell, `VBoxManage`, `kubectl`. All VM lifecycle,
  disk and network configuration happens here.
- **The VMs**: reach them over SSH as root. `ssh root@ocne-op`, etc. `ocne-op` is the
  olcnectl operator node and the NFS server; the cluster is driven from `ocne-cp1` or from
  this host.

`VBoxManage` lives at `C:\Program Files\Oracle\VirtualBox`. If it is not on PATH, use the
full path rather than asking the user to fix their environment mid-task.

## Conventions

- Prefer idempotent commands. Many steps get re-run after a rollback.
- Before any `VBoxManage modifyvm` or `storageattach`, confirm the VM is powered off
  (`VBoxManage showvminfo <vm> --machinereadable | findstr VMState`).
- When editing files on the nodes, back up first: `cp file file.bak.$(date +%s)`.
- Snapshot points are listed in the runbook. Remind the user to take one before starting a
  phase that is hard to undo; do not take or delete snapshots yourself without asking.
- Oracle software runs as uid/gid `54321:54321`. Ownership and SELinux context problems are
  the most common cause of pod failures; check those before suspecting the operator.

## What this lab is for

The goal is fluency with the Oracle Database Operator workflow: custom resources,
reconciliation, status conditions, RBAC scoping, and lifecycle operations. Phases run
SingleInstanceDatabase + Data Guard first, then Oracle Restart with ASM, then RAC. Earlier
phases exist to de-risk later ones, so do not skip ahead even if a later phase looks more
interesting.

## Things that are known-tricky

These have specific handling in the runbook. If you hit them, check there before improvising:

- Hyper-V / Memory Integrity still enabled on the host
- UEK8 vs UEK7 kernel on Oracle Linux 9.8
- cert-manager version vs Kubernetes 1.29
- NFS mount options (`ORA-27054`)
- SELinux denials inside RAC pods
- VirtualBox refusing snapshots when shareable disks are attached
- USB Ethernet adapter renaming or sleeping
