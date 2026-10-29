# AWS VPC Peering — Student Project

**Student:** Subasri S 
**Department:** Information Technology  
**Institution:** University College of Engineering Villupuram  
**Platform:** Amazon Web Services (AWS)  
**Status:** Documentation and scripts prepared; live AWS validation/evidence is pending.

## Project overview
This project is designed to demonstrate private IPv4 communication between two non-overlapping Amazon VPCs using VPC Peering. The workbook design uses VPC A (`10.10.0.0/16`) and VPC B (`10.20.0.0/16`), with a public bastion in VPC A and private application instances in each VPC.

## Architecture plan
- VPC A: `10.10.0.0/16`
  - Public subnet: `10.10.1.0/24` — bastion host
  - Private subnet: `10.10.2.0/24` — App-A
- VPC B: `10.20.0.0/16`
  - Private subnet: `10.20.1.0/24` — App-B
- One VPC Peering connection between VPC A and VPC B.
- VPC B has no Internet Gateway. Both application instances should use private IP addresses and have no public IPv4 address.

> These are planned example CIDRs from the project workbook, not proof that the resources exist in an AWS account. Replace all example values with the actual values from your lab.

## Repository contents
- `scripts/deploy.sh` — AWS CLI deployment workflow (review carefully before running).
- `scripts/test.sh` — baseline, connectivity and controlled-failure tests.
- `scripts/cleanup.sh` — lab resource cleanup workflow.
- `docs/Project_Report.pdf` — report draft and evidence checklist.
- `diagrams/architecture.svg` — logical architecture illustration.
- `evidence/README.md` — evidence checklist and safe placeholders.
- `evidence/sample-test-output.txt` — explicitly simulated example only; not captured from AWS.

## Requirements
- AWS CLI v2 configured for an approved lab account.
- Permissions for VPC, EC2, security groups, route tables, peering and key pairs.
- OpenSSH client and a Linux/WSL shell.
- A cost check before creating EC2/public IPv4 resources.

## Suggested workflow
1. Read the EWB student workbook and this report.
2. Review every script and confirm the account, Region, resource names and costs.
3. Set the student name and Region, then run deployment in the documented phases only if your AWS account has permission.
4. Save real screenshots and actual command output in `evidence/`.
5. Update the report's results and conclusion only after testing.
6. Run cleanup after saving evidence, and verify the account has no lab resources left.

## Security and honesty
Never commit private keys (`.pem`), credentials, access tokens, `~/.aws/credentials`, or unredacted sensitive account details. Do not open SSH to `0.0.0.0/0`. Do not present simulated output as a real AWS test.

## Learning outcomes
- VPC CIDR and subnet planning
- Route tables and subnet associations
- Peering activation and bidirectional routes
- Least-privilege security groups
- Private connectivity testing and troubleshooting
- Safe cloud resource cleanup and cost awareness

## References
- AWS VPC Peering: https://docs.aws.amazon.com/vpc/latest/peering/what-is-vpc-peering.html
- VPC peering routes: https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-routing.html
- AWS pricing: https://aws.amazon.com/pricing/
