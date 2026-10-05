# Remote backend: same S3 state bucket as jalcalaroot-aws-bootstrap and the
# other repos, with its own key. Needed so GitHub Actions (ephemeral runners)
# can chain plan/apply across runs. Native S3 locking (use_lockfile,
# Terraform >= 1.10), no DynamoDB. The bucket name embeds the account ID;
# Terraform does not allow variables inside a `backend` block.
terraform {
  backend "s3" {
    bucket       = "jalcalaroot-tfstate-740104998573"
    key          = "aws-azure-interconnect/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
