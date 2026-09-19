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
