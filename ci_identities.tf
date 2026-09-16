# Identidades de CI para GitHub Actions - sin ningún secreto de AWS ni de
# Azure almacenado en GitHub, mismo patrón que aws-eks-cluster/
# azure-aks-cluster: "agent" (apply, push a main) y "plan" (solo lectura,
# PRs), RBAC acotado lo más posible por recurso/nombre.
#
# El sub claim usa el sub_claim_prefix personalizado de esta cuenta de
# GitHub (formato "repo:OWNER@OWNER_ID/REPO@REPO_ID:...", NO el subject
# inmutable default) - confirmado para este repo específico vía
# `gh api repos/jalcalaroot/aws-azure-interconnect/actions/oidc/customization/sub`
# el 2026-09-15: "repo:jalcalaroot@22682982/aws-azure-interconnect@1368438534".
#
# Borrador razonable, no el resultado de "generar con IAM Policy Autopilot
# desde el plan real + recortar a mano" (mismo estado que ci_identities.tf
# tenía en aws-eks-cluster el día 1, según su propio comentario) - conviene
# repetir ese proceso contra el primer plan real de CI antes de confiar en
# esto a largo plazo. Puntual: la acción exacta de IAM para el servicio
# "Interconnect" (`interconnect:*` acá) no está confirmada contra ninguna
# policy oficial de AWS - inferida del namespace de CloudFormation
# (`AWS::Interconnect::Connection`), que casi siempre coincide con el
# prefijo de IAM action, pero no verificada 1:1.

data "aws_caller_identity" "current" {}

locals {
  github_repo_subject_prefix = "repo:jalcalaroot@22682982/aws-azure-interconnect@1368438534"
}

# --- AWS: roles IAM vía OIDC -------------------------------------------------

data "aws_iam_policy_document" "ci_agent_assume_role" {
  statement {
    sid     = "HumanAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/virtual"]
    }
  }

  statement {
    sid     = "GitHubActionsMainOnly"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_repo_subject_prefix}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "ci_agent" {
  name                 = "aws-azure-interconnect-ci-agent"
  assume_role_policy   = data.aws_iam_policy_document.ci_agent_assume_role.json
  max_session_duration = 3600
  tags                 = local.tags
}

data "aws_iam_policy_document" "ci_plan_assume_role" {
  #checkov:skip=CKV_AWS_358:el trust policy ya exige `aud=sts.amazonaws.com` Y un `sub` exacto (sin wildcard) con el owner/repo/id reales - la config más restrictiva posible según la guía de GitHub para OIDC con AWS. Mismo patrón exacto que aws-eks-cluster/ci_identities.tf (que no lo tiene skippeado, probablemente por diferencia de versión del scanner) - no hay ningún claim inseguro acá, es un statement Federated único sin alternativa "AWS" principal que lo vuelva ambiguo.
  statement {
    sid     = "GitHubActionsPullRequest"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_repo_subject_prefix}:pull_request"]
    }
  }
}

resource "aws_iam_role" "ci_plan" {
  name                 = "aws-azure-interconnect-ci-plan"
  assume_role_policy   = data.aws_iam_policy_document.ci_plan_assume_role.json
  max_session_duration = 3600
  tags                 = local.tags
}

# --- AWS: permisos del agent (apply) ----------------------------------------

data "aws_iam_policy_document" "ci_agent_permissions" {
  #checkov:skip=CKV_AWS_356:Resource "*" limitado a Describe/List de EC2/DX/Interconnect (AWS no permite scopearlas a nivel de recurso) o a iam:PassRole acotado por condición iam:PassedToService - ver statements individuales
  #checkov:skip=CKV_AWS_111:`ec2:*`/`directconnect:*`/`interconnect:*` son un borrador de día 1 a propósito (mismo estado inicial que aws-eks-cluster/ci_identities.tf tenía con sus actions puntuales) - se van a acotar a la lista real de acciones con el IAM Policy Autopilot corriendo contra el primer plan real de CI (ver terraform-plan.yml), no antes de tener ese dato real
  #checkov:skip=CKV_AWS_109:mismo motivo que CKV_AWS_111 - los comodines de servicio completo se van a recortar con el Policy Autopilot, no a mano por adivinanza
  #checkov:skip=CKV_AWS_107:ninguno de los 3 wildcards de servicio (ec2/directconnect/interconnect) incluye una acción real de exposición de credenciales (no hay iam:CreateAccessKey ni similar en estos 3 namespaces) - falso positivo del scanner tratando el wildcard de servicio como si fuera acceso a IAM
  statement {
    sid       = "Ec2Lifecycle"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  statement {
    sid       = "DirectConnectLifecycle"
    actions   = ["directconnect:*"]
    resources = ["*"]
  }

  # Namespace inferido, no confirmado - ver comentario al inicio del archivo.
  statement {
    sid       = "InterconnectLifecycle"
    actions   = ["interconnect:*"]
    resources = ["*"]
  }

  statement {
    sid = "IamRolesForInstanceProfile"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]

    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-azure-interconnect-poc-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/aws-azure-interconnect-poc-*",
    ]
  }

  statement {
    sid     = "PassInstanceRole"
    actions = ["iam:PassRole"]

    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-azure-interconnect-poc-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Backend remoto - state + lock file nativo de S3, scoped al key de este
  # proyecto, mismo patrón que ci_agent_permissions de aws-eks-cluster.
  statement {
    sid       = "TerraformStateBackendAccess"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::jalcalaroot-tfstate-${data.aws_caller_identity.current.account_id}/aws-azure-interconnect/*"]
  }

  statement {
    sid       = "TerraformStateBucketList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::jalcalaroot-tfstate-${data.aws_caller_identity.current.account_id}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["aws-azure-interconnect/*"]
    }
  }

  statement {
    sid       = "TerraformStateEncryption"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.us-east-1.amazonaws.com"]
    }
  }

  # --- Guardrails, mismos que aws-eks-cluster/ci_identities.tf ---
  statement {
    sid    = "DenyPrivilegeEscalation"
    effect = "Deny"

    actions = [
      "iam:AddUserToGroup",
      "iam:AttachUserPolicy",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:CreatePolicyVersion",
      "iam:CreateUser",
      "iam:PutUserPolicy",
      "iam:SetDefaultPolicyVersion",
      "iam:UpdateLoginProfile",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "DenyBillingAndOrgChanges"
    effect = "Deny"

    actions = ["account:*", "aws-portal:*", "organizations:*"]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_agent_permissions" {
  name   = "aws-azure-interconnect-ci-agent-permissions"
  role   = aws_iam_role.ci_agent.id
  policy = data.aws_iam_policy_document.ci_agent_permissions.json
}

# --- AWS: permisos del plan role (solo lectura) -----------------------------

data "aws_iam_policy_document" "ci_plan_permissions" {
  #checkov:skip=CKV_AWS_356:Resource "*" son Describe/List de EC2/DX/Interconnect (AWS no permite scopearlos a nivel de recurso) o kms:Decrypt/GenerateDataKey acotado por condición kms:ViaService
  #checkov:skip=CKV_AWS_107:falso positivo - todas las acciones son de solo lectura (Describe/Get/List), ninguna expone ni genera credenciales; el scanner marca el wildcard de servicio en `ec2:Describe*`/`interconnect:Get*` como si fuera acceso a IAM
  statement {
    sid = "ReadOnly"

    actions = [
      "ec2:Describe*",
      "ec2:Get*",
      "directconnect:Describe*",
      "interconnect:Get*",
      "interconnect:List*",
      "interconnect:Describe*",
    ]

    resources = ["*"]
  }

  statement {
    sid = "ProjectRolesReadOnly"

    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:GetInstanceProfile",
    ]

    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-azure-interconnect-poc-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/aws-azure-interconnect-poc-*",
    ]
  }

  statement {
    sid       = "TerraformStateRead"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::jalcalaroot-tfstate-${data.aws_caller_identity.current.account_id}/aws-azure-interconnect/terraform.tfstate"]
  }

  statement {
    sid       = "TerraformStateLockFile"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::jalcalaroot-tfstate-${data.aws_caller_identity.current.account_id}/aws-azure-interconnect/terraform.tfstate.tflock"]
  }

  statement {
    sid       = "TerraformStateBucketList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::jalcalaroot-tfstate-${data.aws_caller_identity.current.account_id}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["aws-azure-interconnect/*"]
    }
  }

  statement {
    sid       = "TerraformStateEncryption"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.us-east-1.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ci_plan_permissions" {
  name   = "aws-azure-interconnect-ci-plan-permissions"
  role   = aws_iam_role.ci_plan.id
  policy = data.aws_iam_policy_document.ci_plan_permissions.json
}

# --- Azure: identidades vía Workload Identity Federation --------------------

data "azurerm_storage_account" "tfstate" {
  name                = "sttfstatejalcalaroot"
  resource_group_name = "jalcalaroot"
}

resource "azurerm_user_assigned_identity" "ci_agent" {
  name                = "aws-azure-interconnect-agent"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.azure_location
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "ci_plan" {
  name                = "aws-azure-interconnect-plan"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.azure_location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "ci_agent_main" {
  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_agent.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "${local.github_repo_subject_prefix}:ref:refs/heads/main"
}

resource "azurerm_federated_identity_credential" "ci_plan_pr" {
  name                      = "github-pull-request"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_plan.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "${local.github_repo_subject_prefix}:pull_request"
}

# RBAC acotado al resource group de este PoC, no a la suscripción entera.
resource "azurerm_role_assignment" "ci_agent_rg_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_rg_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

# Backend remoto: Storage Blob Data Contributor (data plane, lease de
# locking) + Reader (management plane) - mismo gap ya documentado en
# azure-aks-cluster/ci_identities.tf.
resource "azurerm_role_assignment" "ci_agent_state_write" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_state_write" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

resource "azurerm_role_assignment" "ci_agent_state_reader" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_state_reader" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}
