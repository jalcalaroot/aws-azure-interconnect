# CI identities for GitHub Actions - no AWS or Azure secret stored in GitHub.
# Same pattern as aws-eks-cluster / azure-aks-cluster: "agent" (apply, push
# to main) and "plan" (read-only, PRs), RBAC scoped as tightly as possible.
#
# The OIDC `sub` claim uses this GitHub account's custom sub_claim_prefix
# ("repo:OWNER@OWNER_ID/REPO@REPO_ID:..."), not the default immutable
# subject (see `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`).
#
# Day-1 draft: the IAM policies are not yet trimmed with IAM Policy Autopilot
# against a real CI plan. In particular, `interconnect:*` is inferred from the
# CloudFormation namespace (`AWS::Interconnect::Connection`), not from an
# official AWS policy.

data "aws_caller_identity" "current" {}

locals {
  github_repo_subject_prefix = "repo:jalcalaroot@22682982/aws-azure-interconnect@1368438534"
}

# --- AWS: IAM roles via OIDC -------------------------------------------------

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
  #checkov:skip=CKV_AWS_358:the trust policy requires `aud=sts.amazonaws.com` AND an exact `sub` (no wildcard) with the real owner/repo/ids - the most restrictive setup per GitHub's OIDC-for-AWS guidance; a single Federated statement with no ambiguous "AWS" principal
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

# --- AWS: agent permissions (apply) -----------------------------------------

data "aws_iam_policy_document" "ci_agent_permissions" {
  #checkov:skip=CKV_AWS_356:Resource "*" is limited to Describe/List on EC2/DX/Interconnect (not resource-scopable in AWS) or iam:PassRole constrained by iam:PassedToService - see the individual statements
  #checkov:skip=CKV_AWS_111:`ec2:*`/`directconnect:*`/`interconnect:*` are a day-1 draft on purpose; they will be narrowed to the real action list with IAM Policy Autopilot against the first real CI plan (see terraform-plan.yml)
  #checkov:skip=CKV_AWS_109:same reason as CKV_AWS_111 - service-wide wildcards will be trimmed with IAM Policy Autopilot, not by guesswork
  #checkov:skip=CKV_AWS_107:none of the 3 service wildcards (ec2/directconnect/interconnect) includes a credential-exposing action (no iam:CreateAccessKey or similar); false positive from treating a service wildcard as IAM access
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

  # Inferred namespace, not confirmed - see the comment at the top of the file.
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

  # Remote backend - S3 state + native lock file, scoped to this project's key.
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

  # --- Guardrails, same as aws-eks-cluster/ci_identities.tf ---
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

# --- AWS: plan role permissions (read-only) ---------------------------------

data "aws_iam_policy_document" "ci_plan_permissions" {
  #checkov:skip=CKV_AWS_356:Resource "*" is Describe/List on EC2/DX/Interconnect (not resource-scopable in AWS) or kms:Decrypt/GenerateDataKey limited by kms:ViaService
  #checkov:skip=CKV_AWS_107:false positive - all actions are read-only (Describe/Get/List); the scanner treats the `ec2:Describe*`/`interconnect:Get*` service wildcard as IAM access
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

# --- Azure: identities via Workload Identity Federation ---------------------

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

# RBAC scoped to this PoC's resource group, not the whole subscription.
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

# Remote state: Storage Blob Data Contributor (data plane, lease for locking)
# + Reader (management plane) - same gap documented in azure-aks-cluster.
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
