#!/usr/bin/env bash
# EWB VPC Peering - cleanup (workbook page 14).
# Removes ONLY resources recorded in ewb-state.env. Save your evidence first.
# Output is saved to ./evidence/cleanup-*.txt as your cleanup evidence.

set -uo pipefail

STATE_FILE="ewb-state.env"
[ -f "$STATE_FILE" ] || { echo "No $STATE_FILE - nothing recorded to clean up."; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
export AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""

mkdir -p evidence
exec > >(tee "evidence/cleanup-$(date +%Y%m%d-%H%M%S).txt") 2>&1

echo "This will delete the lab resources listed in $STATE_FILE (Region $REGION)."
read -r -p "Type 'yes' to continue: " ok
[ "$ok" = "yes" ] || { echo "Cancelled."; exit 0; }

step() { echo; echo "==> $*"; }
try()  { "$@" >/dev/null 2>&1 && echo "  ok: $*" || echo "  skipped (already gone or not set): ${*:1:4}"; }

step "1. Terminate instances (their lab EBS volumes delete on termination)"
INSTANCES=$(echo "${BASTION:-} ${APP_A:-} ${APP_B:-}" | xargs)
if [ -n "$INSTANCES" ]; then
  aws ec2 terminate-instances --instance-ids $INSTANCES --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text
  aws ec2 wait instance-terminated --instance-ids $INSTANCES && echo "  all instances terminated"
fi
step "   Remove lab key pair and local key"
try aws ec2 delete-key-pair --key-name "${KEY_NAME:-ewb-lab}"
rm -f "$HOME/.ssh/ewb-lab.pem" ewb-ssh-config && echo "  local key and ssh config removed"

step "2. Remove peer routes and the peering connection"
[ -n "${RT_A_PRIV:-}" ] && try aws ec2 delete-route --route-table-id "$RT_A_PRIV" --destination-cidr-block 10.20.0.0/16
[ -n "${RT_B_PRIV:-}" ] && try aws ec2 delete-route --route-table-id "$RT_B_PRIV" --destination-cidr-block 10.10.0.0/16
[ -n "${RT_A_PUB:-}"  ] && try aws ec2 delete-route --route-table-id "$RT_A_PUB"  --destination-cidr-block 10.20.0.0/16
[ -n "${PCX:-}" ] && try aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX"

step "   Delete security groups (retry while network interfaces disappear)"
for sg in "${SG_BASTION:-}" "${SG_APP_A:-}" "${SG_APP_B:-}"; do
  [ -z "$sg" ] && continue
  for i in 1 2 3 4 5 6; do
    aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 && { echo "  ok: deleted $sg"; break; }
    [ "$i" = 6 ] && echo "  could not delete $sg - check for leftover network interfaces"
    sleep 10
  done
done

step "   Disassociate and delete subnets and custom route tables"
for a in "${ASSOC_A_PUB:-}" "${ASSOC_A_PRIV:-}" "${ASSOC_B_PRIV:-}"; do
  [ -n "$a" ] && try aws ec2 disassociate-route-table --association-id "$a"
done
for rt in "${RT_A_PUB:-}" "${RT_A_PRIV:-}" "${RT_B_PRIV:-}"; do [ -n "$rt" ] && try aws ec2 delete-route-table --route-table-id "$rt"; done
for sn in "${PUB_A:-}" "${PRIV_A:-}" "${PRIV_B:-}"; do [ -n "$sn" ] && try aws ec2 delete-subnet --subnet-id "$sn"; done

step "   Detach and delete the internet gateway, then delete both VPCs"
if [ -n "${IGW:-}" ]; then
  try aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "${VPC_A:-}"
  try aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
fi
for v in "${VPC_A:-}" "${VPC_B:-}"; do [ -n "$v" ] && try aws ec2 delete-vpc --vpc-id "$v"; done

step "3. Verify the account is clear (filtered by Project tag)"
echo "Instances not terminated:"
aws ec2 describe-instances --filters "Name=tag:Project,Values=EWB-VPC-Peering" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text
echo "Volumes:";   aws ec2 describe-volumes --filters "Name=tag:Project,Values=EWB-VPC-Peering" --query 'Volumes[].VolumeId' --output text
echo "VPCs:";      aws ec2 describe-vpcs --filters "Name=tag:Project,Values=EWB-VPC-Peering" --query 'Vpcs[].VpcId' --output text
echo "Elastic IPs:"; aws ec2 describe-addresses --filters "Name=tag:Project,Values=EWB-VPC-Peering" --query 'Addresses[].AllocationId' --output text
echo "Snapshots:"; aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Project,Values=EWB-VPC-Peering" --query 'Snapshots[].SnapshotId' --output text
echo; echo "Empty lines above mean nothing remains. Also check Billing later; usage reporting can lag."
mv "$STATE_FILE" "${STATE_FILE}.cleaned"
