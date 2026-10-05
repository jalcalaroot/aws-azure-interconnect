# aws-azure-interconnect

Terraform PoC: private AWS (us-east-1, `10.100.0.0/16`) <-> Azure (East US, `10.200.0.0/16`) connectivity over AWS Interconnect - multicloud and Azure Multicloud Interconnect (preview). Lives in `multicloud/` because it belongs to both clouds. See `README.md` for architecture, usage and test commands.

## Status

Working and verified end-to-end on real accounts (2026-10-05): handshake `available`/`Provisioned`, 4 BGP sessions, ping, `telnet` 22/80 and `curl` in both directions. The stack is torn down after testing; nothing is meant to stay deployed.

## Rules for working in this repo

- **Never `apply` without explicit approval.** The ExpressRoute gateway costs ~$0.19/h and takes 30-60 min to create/delete; AWS may also bill the 1 Gbps interconnect ($1.37/h, unconfirmed).
- **Always verify the teardown by hand** after `destroy` (`az resource list -g rg-aws-azure-interconnect-poc`, `aws ec2 describe-vpcs`, `aws directconnect describe-direct-connect-gateways`). An interrupted `apply` can leave resources that are not in state.
- Do not change `aws-vpc` or `azure-virtual-network` for this PoC; they are generic, versioned modules.
- `terraform.tfvars` is git-ignored and holds the subscription ID and a dedicated SSH public key.

## Running Terraform

The snap `terraform`/`gcloud` binaries print nothing in this environment. Use Docker. `azurerm` needs `az`, so use the Azure CLI image and install Terraform in it (it has no `unzip`; use `python3 -m zipfile`):

```bash
docker run --rm -e ARM_USE_CLI=true -e AWS_PROFILE=default -e AWS_REGION=us-east-1 \
  -v "$PWD":/wd -v ~/.azure:/root/.azure -v ~/.aws:/root/.aws:ro -w /wd \
  mcr.microsoft.com/azure-cli:latest sh -c '<install terraform 1.10.x; then terraform ...>'
```

The image is Azure Linux (`tdnf`, not `apk`); install `git` for the module downloads. `terraform fmt`/`validate` work with `hashicorp/terraform:1.10` and `init -backend=false`. `tflint` and `checkov` run locally. `.terraform.lock.hcl` is tracked; run `init -upgrade` after bumping providers. Plans can contain sensitive values: keep them out of the repo.

## Design decisions

- **Region pair** us-east-1 <-> East US (the only preview pair that includes N. Virginia). CIDRs must not overlap.
- **Azure circuit via `azapi`**: `Microsoft.Network/expressRouteCircuits@2025-09-01`, tier `MultiCloud`, `partnerAccountId`, redeem `activationKey` (not `serviceKey`). `azurerm` 5.8 does not expose these; `azapi` 2.13 does not embed that API version, so `schema_validation_enabled = false`. Bandwidth is 1 Gbps on both sides (the key is validated against it).
- **AWS side via `awscc`**: `hashicorp/aws` has no Interconnect resource. Attach point is a DX Gateway associated with a VGW (a TGW is not worth it for one VPC).
- **Test hosts**: Ubuntu 24.04 on both sides with one shared bootstrap (`local.test_server_bootstrap`): nginx :80 (hello world), sshd :22, `python3 -m http.server` on 443/8080 (no TLS). No public IP, no SSH/RDP exposure; access via SSM (AWS) and Run Command (Azure). Traffic is allowed only from the other cloud's CIDR.
- **Cheapest viable sizes**: `az_count = 1` (regional NAT bills per AZ), ExpressRoute gateway `Standard`, Azure VM `Standard_F1als_v7` (`Standard_B1ls` has no capacity in this subscription; v7 needs `disk_controller_type = "NVMe"` and a Gen2 image).
- **AWS routing gaps** handled in `routing.tf`: route to `10.200.0.0/16` via the VGW on the `compute` route table, and NACL rules (including ephemeral-port egress) on the `private` NACL. Azure needs nothing extra (BGP propagation, `VirtualNetwork` service tag).

## Known issues and gotchas

- **`plan`/`validate` cannot see** globally unique name collisions, SKU capacity errors, or apply-time ordering. The storage account / Key Vault names are overridden in `network.tf` for that reason.
- **`aws-vpc` route table drift**: its `compute` route table uses inline routes, so the standalone `aws_route` to Azure is removed and re-created on every plan (seconds without the route). Accepted for this PoC.
- **Destroy blockers** seen before: a stale state lock (`terraform force-unlock`), `lifecycle.prevent_destroy` inside `azure-virtual-network` (edit the cached module copy only for that destroy), and auto-created `NWTA-*` Insights resources blocking the resource group delete (delete by hand).
- **Peering state** shows `Disabled` in the circuit JSON even with BGP up; ignore it.
- `telnet` in scripts: send the request with `\n`, not `\r\n`, or nginx returns `400`.

## CI

`terraform-validate` (fmt, validate, tflint, checkov), `gitleaks` and `scorecard` need no secrets. `terraform-plan`/`terraform-apply` use OIDC (`ci_identities.tf`) and are skipped (`if: vars.AWS_ROLE_ARN_* != ''`) until the repository variables are set (`AWS_ROLE_ARN_*`, `ARM_CLIENT_ID_*`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, `AZURE_VM_SSH_PUBLIC_KEY`). **Once set, `terraform-apply` runs on every push to `main` that changes `*.tf`**: configure them only on purpose.

## Open items

- Confirm in Cost Explorer whether AWS bills the 1 Gbps interconnect with Azure, and update the README cost table.
- Load the CI variables and apply the Azure side of `ci_identities.tf` only when CI should be live.
- The IAM action namespace `interconnect:*` is inferred from `AWS::Interconnect::Connection`, not from an official policy; trim it with the real plan.
