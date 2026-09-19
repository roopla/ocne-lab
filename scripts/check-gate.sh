#!/usr/bin/env bash
# Verify a phase gate. Run from the Windows host (Git Bash) or from ocne-op.
# Usage: ./check-gate.sh <0|3|4|5|6>
# Read-only. Prints PASS/FAIL per check and exits non-zero if anything failed.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./lab.env 2>/dev/null || true

FAILED=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }
head() { printf '\n== %s ==\n' "$1"; }

# Run a command on a node over SSH
on() { ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$1" "$2" 2>/dev/null; }

check_ssh() {
  for h in $ALL_VMS; do
    if on "$h" true; then pass "ssh root@$h"; else fail "ssh root@$h (no passwordless login)"; fi
  done
}

gate3() {
  head "Phase 3 gate: VMs, networking, SSH"
  check_ssh
  for h in $ALL_VMS; do
    ip=$(on "$h" "hostname -I | awk '{print \$1}'")
    [ -n "$ip" ] && pass "$h has address $ip" || fail "$h has no address"
  done
  for w in $WORKERS; do
    n=$(on "$w" "ip -br addr | grep -c 'UP .*$'")
    priv=$(on "$w" "nmcli -t -f NAME con show | grep -c '^priv'")
    [ "${priv:-0}" -ge 2 ] && pass "$w has priv1 and priv2" || fail "$w missing private connections"
  done
}

gate4() {
  head "Phase 4 gate: storage"
  for w in $WORKERS; do
    for d in sdc sdd sde; do
      fs=$(on "$w" "lsblk -no FSTYPE /dev/$d | tr -d ' \n'")
      if [ -z "$fs" ]; then pass "$w /dev/$d is raw"; else fail "$w /dev/$d has filesystem '$fs' -- ASM disks must be raw"; fi
    done
    on "$w" "mountpoint -q /var/lib/containers" && pass "$w /var/lib/containers mounted" || fail "$w /var/lib/containers not mounted"
    on "$w" "mountpoint -q $STAGE_MOUNT"       && pass "$w stage mounted"                || fail "$w $STAGE_MOUNT not mounted"
    on "$w" "test -w $STAGE_MOUNT"             && pass "$w stage writable"                || fail "$w stage not writable"
  done
  on "$OP_VM" "exportfs -v | grep -q $NFS_EXPORT_STAGE" && pass "NFS export present" || fail "NFS export missing"
}

gate5() {
  head "Phase 5 gate: OCNE cluster"
  nodes=$(on "$CP1_VM" "kubectl get nodes --no-headers 2>/dev/null | wc -l")
  ready=$(on "$CP1_VM" "kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready")
  [ "${nodes:-0}" -eq 3 ] && pass "3 nodes registered" || fail "expected 3 nodes, got ${nodes:-0}"
  [ "${ready:-0}" -eq 3 ] && pass "3 nodes Ready"      || fail "expected 3 Ready, got ${ready:-0}"

  # node IPs must be the static LAN addresses, not DHCP
  for pair in "$CP1_HOST:$CP1_IP" "$W1_HOST:$W1_IP" "$W2_HOST:$W2_IP"; do
    h=${pair%%:*}; want=${pair##*:}
    got=$(on "$CP1_VM" "kubectl get node $h -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'")
    [ "$got" = "$want" ] && pass "$h INTERNAL-IP $got" || fail "$h INTERNAL-IP is '$got', expected $want"
  done

  bad=$(on "$CP1_VM" "kubectl get pods -n kube-system --no-headers | grep -vc ' Running\\| Completed'")
  [ "${bad:-1}" -eq 0 ] && pass "all kube-system pods Running" || fail "${bad} kube-system pods not Running"
}

gate6() {
  head "Phase 6 gate: operator"
  r=$(on "$CP1_VM" "kubectl get deploy oracle-database-operator-controller-manager -n $NS_OPERATOR -o jsonpath='{.status.readyReplicas}'")
  [ "${r:-0}" -ge 1 ] && pass "controller-manager ready ($r replicas)" || fail "controller-manager not ready"

  for ns in "$NS_OPERATOR" "$NS_SIDB" "$NS_RAC"; do
    a=$(on "$CP1_VM" "kubectl auth can-i list singleinstancedatabases.database.oracle.com --as=system:serviceaccount:$NS_OPERATOR:oracle-database-operator-controller-manager -n $ns")
    [ "$a" = "yes" ] && pass "RBAC ok in $ns" || fail "RBAC missing in $ns (got '$a')"
  done

  for crd in singleinstancedatabases dataguardbrokers oraclerestarts racdatabases; do
    on "$CP1_VM" "kubectl get crd ${crd}.database.oracle.com >/dev/null 2>&1" \
      && pass "CRD $crd" || fail "CRD $crd missing"
  done

  on "$CP1_VM" "kubectl get validatingwebhookconfiguration validating-webhook-configuration >/dev/null 2>&1" \
    && pass "validating webhook" || fail "validating webhook missing"
  on "$CP1_VM" "kubectl get pods -n cert-manager --no-headers | grep -q Running" \
    && pass "cert-manager running" || fail "cert-manager not running"
}

case "${1:-}" in
  3) gate3 ;;
  4) gate4 ;;
  5) gate5 ;;
  6) gate6 ;;
  all) gate3; gate4; gate5; gate6 ;;
  *) echo "Usage: $0 <3|4|5|6|all>"; exit 2 ;;
esac

echo
[ $FAILED -eq 0 ] && echo "GATE PASSED" || echo "GATE FAILED"
exit $FAILED
