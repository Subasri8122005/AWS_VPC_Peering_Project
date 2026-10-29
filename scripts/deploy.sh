#!/usr/bin/env bash
# EWB Cloud Labs - AWS VPC Peering project
# Builds the workbook network with the AWS CLI, in two phases so you can
# capture the "before peering" baseline (workbook page 8) before peering exists.
#
#   export STUDENT="Your Name"
#   export AWS_REGION=ap-south-1          # optional, default ap-south-1
#   ./deploy.sh phase1                    # VPCs, subnets, IGW, routes, SGs, instances, SSH config
#   ./test.sh baseline                    # capture the failed ping (no peering yet)
#   ./deploy.sh phase2                    # peering + routes on both sides
#   ./test.sh verify                      # forward/reverse ping, App-B SSH, isolation
#   ./test.sh failure                     # controlled ICMP failure and recovery
#   ./cleanup.sh                          # remove everything
#
# Requires: AWS CLI v2 configured for a lab account, curl, ssh.

set -euo pipefail

PHASE="${1:-}"
STATE_FILE="ewb-state.env"
REGION="${AWS_REGION:-ap-south-1}"
AZ="${REGION}a"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

: "${STUDENT:?Set STUDENT first, e.g. export STUDENT=\"Your Name\"}"
PROJECT="EWB-VPC-Peering"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

# Address plan (workbook page 4)
VPC_A_CIDR="10.10.0.0/16";  PUB_A_CIDR="10.10.1.0/24"; PRIV_A_CIDR="10.10.2.0/24"
VPC_B_CIDR="10.20.0.0/16";  PRIV_B_CIDR="10.20.1.0/24"
BASTION_IP="10.10.1.10";    APP_A_IP="10.10.2.10";     APP_B_IP="10.20.1.10"

tags() { # tags <resource-type> <name>
  echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=$PROJECT},{Key=Student,Value=$STUDENT}]"
}
save() { echo "$1=$2" >> "$STATE_FILE"; echo "  $1 = $2"; }
say()  { echo; echo "==> $*"; }

phase1() {
  [ -f "$STATE_FILE" ] && { echo "$STATE_FILE already exists. Run ./cleanup.sh first or delete it."; exit 1; }
  : > "$STATE_FILE"
  save REGION "$REGION"

  say "Account check"
  aws sts get-caller-identity --query '[Account,Arn]' --output text

  say "Page 5 / VPC A"
  VPC_A=$(aws ec2 create-vpc --cidr-block "$VPC_A_CIDR" \
    --tag-specifications "$(tags vpc ewb-vpc-a)" --query Vpc.VpcId --output text)
  save VPC_A "$VPC_A"

  PUB_A=$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block "$PUB_A_CIDR" --availability-zone "$AZ" \
    --tag-specifications "$(tags subnet ewb-a-public)" --query Subnet.SubnetId --output text)
  save PUB_A "$PUB_A"
  PRIV_A=$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block "$PRIV_A_CIDR" --availability-zone "$AZ" \
    --tag-specifications "$(tags subnet ewb-a-private)" --query Subnet.SubnetId --output text)
  save PRIV_A "$PRIV_A"

  IGW=$(aws ec2 create-internet-gateway \
    --tag-specifications "$(tags internet-gateway ewb-igw-a)" --query InternetGateway.InternetGatewayId --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_A"
  save IGW "$IGW"

  RT_A_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_A" \
    --tag-specifications "$(tags route-table ewb-rt-a-public)" --query RouteTable.RouteTableId --output text)
  save RT_A_PUB "$RT_A_PUB"
  ASSOC_A_PUB=$(aws ec2 associate-route-table --route-table-id "$RT_A_PUB" --subnet-id "$PUB_A" --query AssociationId --output text)
  save ASSOC_A_PUB "$ASSOC_A_PUB"
  aws ec2 create-route --route-table-id "$RT_A_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null

  RT_A_PRIV=$(aws ec2 create-route-table --vpc-id "$VPC_A" \
    --tag-specifications "$(tags route-table ewb-rt-a-private)" --query RouteTable.RouteTableId --output text)
  save RT_A_PRIV "$RT_A_PRIV"
  ASSOC_A_PRIV=$(aws ec2 associate-route-table --route-table-id "$RT_A_PRIV" --subnet-id "$PRIV_A" --query AssociationId --output text)
  save ASSOC_A_PRIV "$ASSOC_A_PRIV"

  say "Page 6 / VPC B (no internet gateway)"
  VPC_B=$(aws ec2 create-vpc --cidr-block "$VPC_B_CIDR" \
    --tag-specifications "$(tags vpc ewb-vpc-b)" --query Vpc.VpcId --output text)
  save VPC_B "$VPC_B"
  PRIV_B=$(aws ec2 create-subnet --vpc-id "$VPC_B" --cidr-block "$PRIV_B_CIDR" --availability-zone "$AZ" \
    --tag-specifications "$(tags subnet ewb-b-private)" --query Subnet.SubnetId --output text)
  save PRIV_B "$PRIV_B"
  RT_B_PRIV=$(aws ec2 create-route-table --vpc-id "$VPC_B" \
    --tag-specifications "$(tags route-table ewb-rt-b-private)" --query RouteTable.RouteTableId --output text)
  save RT_B_PRIV "$RT_B_PRIV"
  ASSOC_B_PRIV=$(aws ec2 associate-route-table --route-table-id "$RT_B_PRIV" --subnet-id "$PRIV_B" --query AssociationId --output text)
  save ASSOC_B_PRIV "$ASSOC_B_PRIV"

  say "Page 6 / Security groups (no 0.0.0.0/0 on SSH or ICMP)"
  MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
  echo "  Your public IPv4: $MY_IP"
  save MY_IP "$MY_IP"

  SG_BASTION=$(aws ec2 create-security-group --group-name ewb-sg-bastion --description "EWB bastion SSH" \
    --vpc-id "$VPC_A" --tag-specifications "$(tags security-group ewb-sg-bastion)" --query GroupId --output text)
  SG_APP_A=$(aws ec2 create-security-group --group-name ewb-sg-app-a --description "EWB App-A" \
    --vpc-id "$VPC_A" --tag-specifications "$(tags security-group ewb-sg-app-a)" --query GroupId --output text)
  SG_APP_B=$(aws ec2 create-security-group --group-name ewb-sg-app-b --description "EWB App-B" \
    --vpc-id "$VPC_B" --tag-specifications "$(tags security-group ewb-sg-app-b)" --query GroupId --output text)
  save SG_BASTION "$SG_BASTION"; save SG_APP_A "$SG_APP_A"; save SG_APP_B "$SG_APP_B"

  aws ec2 authorize-security-group-ingress --group-id "$SG_BASTION" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32,Description=my-laptop-ssh}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_A" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${BASTION_IP}/32,Description=bastion-ssh}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_A" \
    --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=${APP_B_IP}/32,Description=app-b-echo}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_B" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${BASTION_IP}/32,Description=bastion-ssh}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_APP_B" \
    --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=${APP_A_IP}/32,Description=app-a-echo}]" >/dev/null

  say "Page 7 / Key pair (stored locally only)"
  mkdir -p "$HOME/.ssh"
  aws ec2 create-key-pair --key-name ewb-lab --key-type rsa \
    --tag-specifications "$(tags key-pair ewb-lab)" --query KeyMaterial --output text > "$HOME/.ssh/ewb-lab.pem"
  chmod 400 "$HOME/.ssh/ewb-lab.pem"
  save KEY_NAME ewb-lab

  say "Page 7 / Instances (Amazon Linux 2023, $INSTANCE_TYPE)"
  AMI=$(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)
  save AMI "$AMI"
  DISK='[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true}}]'

  launch() { # launch <name> <subnet> <ip> <sg> <public-flag>
    aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --key-name ewb-lab \
      --subnet-id "$2" --private-ip-address "$3" --security-group-ids "$4" "$5" \
      --block-device-mappings "$DISK" \
      --tag-specifications "$(tags instance "$1")" "$(tags volume "$1")" \
      --query 'Instances[0].InstanceId' --output text
  }
  BASTION=$(launch ewb-bastion "$PUB_A"  "$BASTION_IP" "$SG_BASTION" --associate-public-ip-address)
  APP_A=$(launch   ewb-app-a   "$PRIV_A" "$APP_A_IP"   "$SG_APP_A"   --no-associate-public-ip-address)
  APP_B=$(launch   ewb-app-b   "$PRIV_B" "$APP_B_IP"   "$SG_APP_B"   --no-associate-public-ip-address)
  save BASTION "$BASTION"; save APP_A "$APP_A"; save APP_B "$APP_B"

  echo "  Waiting for status checks to pass (a few minutes)..."
  aws ec2 wait instance-status-ok --instance-ids "$BASTION" "$APP_A" "$APP_B"

  BASTION_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$BASTION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  save BASTION_PUBLIC_IP "$BASTION_PUBLIC_IP"

  say "Page 8 / SSH config written to ./ewb-ssh-config"
  cat > ewb-ssh-config <<EOF
# Use with: ssh -F ./ewb-ssh-config ewb-app-a
# or append the Host blocks to ~/.ssh/config.
# StrictHostKeyChecking accept-new trusts a host key on first use only, for lab convenience.
Host *
    StrictHostKeyChecking accept-new

Host ewb-bastion
    HostName $BASTION_PUBLIC_IP
    User ec2-user
    IdentityFile ~/.ssh/ewb-lab.pem
    IdentitiesOnly yes

Host ewb-app-a
    HostName $APP_A_IP
    User ec2-user
    IdentityFile ~/.ssh/ewb-lab.pem
    IdentitiesOnly yes
    ProxyJump ewb-bastion

Host ewb-app-b
    HostName $APP_B_IP
    User ec2-user
    IdentityFile ~/.ssh/ewb-lab.pem
    IdentitiesOnly yes
    ProxyJump ewb-bastion
EOF

  say "Phase 1 complete. Checkpoints 01 and 02: screenshot route tables/associations and instance details."
  echo "Next: ./test.sh baseline   (capture the failed ping BEFORE peering)"
}

phase2() {
  [ -f "$STATE_FILE" ] || { echo "No $STATE_FILE. Run phase1 first."; exit 1; }
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  say "Page 9 / Request and accept peering"
  PCX=$(aws ec2 create-vpc-peering-connection --vpc-id "$VPC_A" --peer-vpc-id "$VPC_B" \
    --tag-specifications "$(tags vpc-peering-connection ewb-a-b-peer)" \
    --query VpcPeeringConnection.VpcPeeringConnectionId --output text)
  save PCX "$PCX"
  aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$PCX" >/dev/null
  aws ec2 wait vpc-peering-connection-exists --vpc-peering-connection-ids "$PCX"
  until [ "$(aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$PCX" \
      --query 'VpcPeeringConnections[0].Status.Code' --output text)" = "active" ]; do sleep 3; done
  aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$PCX" \
    --query 'VpcPeeringConnections[0].{Id:VpcPeeringConnectionId,Status:Status.Code,Requester:RequesterVpcInfo.[VpcId,CidrBlock],Accepter:AccepterVpcInfo.[VpcId,CidrBlock]}'

  say "Page 10 / Routes on both sides (plus the bastion's public subnet)"
  aws ec2 create-route --route-table-id "$RT_A_PRIV" --destination-cidr-block "$VPC_B_CIDR" --vpc-peering-connection-id "$PCX" >/dev/null
  aws ec2 create-route --route-table-id "$RT_B_PRIV" --destination-cidr-block "$VPC_A_CIDR" --vpc-peering-connection-id "$PCX" >/dev/null
  aws ec2 create-route --route-table-id "$RT_A_PUB"  --destination-cidr-block "$VPC_B_CIDR" --vpc-peering-connection-id "$PCX" >/dev/null

  for rt in "$RT_A_PRIV" "$RT_B_PRIV" "$RT_A_PUB"; do
    echo; echo "Route table $rt"
    aws ec2 describe-route-tables --route-table-ids "$rt" \
      --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId||VpcPeeringConnectionId]' --output table
  done
  say "Phase 2 complete. Checkpoints 03 and 04: screenshot peering (Active) and all three route tables."
  echo "Next: ./test.sh verify"
}

case "$PHASE" in
  phase1) phase1 ;;
  phase2) phase2 ;;
  *) echo "Usage: STUDENT=\"Your Name\" $0 phase1|phase2"; exit 1 ;;
esac
