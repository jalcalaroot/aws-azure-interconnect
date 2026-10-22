# Remote backend: same S3 state bucket as jalcalaroot-aws-bootstrap and the
# other repos, with its own key. Needed so GitHub Actions (ephemeral runners)
# can chain plan/apply across runs. Native S3 locking (use_lockfile,
# Terraform >= 1.10), no DynamoDB. The bucket name embeds the account ID;
# Terraform does not allow variables inside a `backend` block.
terraform {
  backend "s3" {
    # bucket = "jalcalaroot-tfstate-<AWS_ACCOUNT_ID>" -> configuracion parcial, no se
    # versiona (incluye el account ID). Local: terraform init -backend-config=backend.hcl
    # (ver backend.hcl.example). CI: se deriva de sts get-caller-identity.
    key          = "aws-azure-interconnect/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
