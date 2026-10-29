#!/usr/bin/env bash
# EWB VPC Peering - evidence capture (workbook page 11).
# Run from your laptop. Every run is logged to ./evidence/ so you can paste real output into your report.
#
#   ./test.sh baseline   Test 01: App-A -> App-B ping BEFORE peering (expected: 100% loss)
#   ./test.sh verify     Tests 02-05: forward ping, reverse ping, SSH to App-B, isolation
#   ./test.sh failure    Controlled failure: remove App-B ICMP rule, ping fails, restore, ping works

set -uo pipefail

STATE_FILE="ewb-state.env"
[ -f "$STATE_FILE" ] || { echo "No $STATE_FILE. Run ./deploy.sh phase1 first."; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
export AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""

SSH="ssh -F ./ewb-ssh-config -o BatchMode=yes -o ConnectTimeout=15"
APP_A_IP="10.10.2.10"; APP_B_IP="10.20.1.10"
mkdir -p evidence
LOG="evidence/$1-$(date +%Y%m%d-%H%M%S).txt"

# Everything printed is also saved to the log file.
exec > >(tee "$LOG") 2>&1

banner() { echo; echo "=================================================="; echo "$*"; echo "=================================================="; }
stamp()  { echo "Time (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
on()     { local host="$1"; shift; echo "\$ [on $host] $*"; $SSH "$host" "$@"; }

identify() { on "$1" "hostname; hostname -I"; }

case "${1:-}" in
baseline)
  banner "TEST 01 / BASELINE - before peering and peer routes"; stamp
  identify ewb-app-a
  on ewb-app-a "ping -c 4 -W 2 $APP_B_IP" || true
  echo; echo "Expected: 100% packet loss (no route to 10.20.0.0/16, no peering)."
  ;;

verify)
  banner "TEST 02 / FORWARD PATH - App-A to App-B"; stamp
  identify ewb-app-a
  on ewb-app-a "ping -c 4 -W 2 $APP_B_IP" || echo "FAILED - see troubleshooting table, page 12"

  banner "TEST 03 / REVERSE PATH - App-B to App-A"; stamp
  identify ewb-app-b
  on ewb-app-b "ping -c 4 -W 2 $APP_A_IP" || echo "FAILED - see troubleshooting table, page 12"

  banner "TEST 04 / PRIVATE SSH - laptop > bastion > App-B (ProxyJump)"; stamp
  echo "\$ ssh ewb-app-b"
  $SSH ewb-app-b "echo 'Shell on App-B reached through the bastion:'; hostname; hostname -I; whoami" \
    || echo "FAILED - see troubleshooting table, page 12"

  banner "TEST 05 / ISOLATION - public IPv4 on App-A and App-B"; stamp
  aws ec2 describe-instances --instance-ids "$APP_A" "$APP_B" \
    --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,InstanceId:InstanceId,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress||`none`}' \
    --output table
  echo "Expected: PublicIp = none for both."
  ;;

failure)
  banner "CONTROLLED FAILURE - App-B ICMP Echo rule (SSH rule stays)"; stamp
  echo "--- Step 1: remove ONLY the ICMP echo rule on ewb-sg-app-b (source $APP_A_IP/32)"
  aws ec2 revoke-security-group-ingress --group-id "$SG_APP_B" \
    --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=${APP_A_IP}/32}]" >/dev/null \
    && echo "Rule removed."
  sleep 5
  stamp
  on ewb-app-a "ping -c 4 -W 2 $APP_B_IP" || true
  echo "Expected: 100% packet loss (rule removed)."

  echo; echo "--- Step 2: restore the exact rule"
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_B" \
    --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=${APP_A_IP}/32,Description=app-a-echo}]" >/dev/null \
    && echo "Rule restored."
  sleep 5
  stamp
  on ewb-app-a "ping -c 4 -W 2 $APP_B_IP" || echo "Still failing - wait a few seconds and re-run."
  echo "Expected: 4 received, 0% packet loss (recovered)."

  echo; echo "--- Current inbound rules on ewb-sg-app-b"
  aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_APP_B" \
    --query 'SecurityGroupRules[?IsEgress==`false`].[IpProtocol,FromPort,ToPort,CidrIpv4]' --output table
  ;;

*)
  echo "Usage: $0 baseline|verify|failure"; exit 1 ;;
esac

echo; echo "Saved to $LOG"
