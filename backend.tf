# Backend remoto real: mismo bucket S3 de tfstate que jalcalaroot-aws-bootstrap
# y aws-vpc/aws-eks-cluster, key propia para no pisar esos states. Necesario
# para que GitHub Actions (runners efímeros, sin disco persistente) pueda
# encadenar plan/apply entre corridas - sin esto, cada run de CI arrancaría
# de cero sin memoria del state anterior. Locking nativo de S3
# (use_lockfile, TF >= 1.10) - sin DynamoDB. El bucket embebe el account ID
# en su nombre - Terraform no permite variables/interpolación dentro de un
# bloque `backend`, así que esto no se puede parametrizar.
terraform {
  backend "s3" {
    bucket       = "jalcalaroot-tfstate-740104998573"
    key          = "aws-azure-interconnect/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
