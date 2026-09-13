# Security Policy

This is a personal PoC/reference repository (AWS + Azure), not intended for production use as-is. There are no supported version branches — only `main` is maintained.

## Reporting a Vulnerability

If you find a security issue — a misconfigured resource default, an overly permissive security group/NSG rule, a leaked credential in git history — please report it privately using [GitHub's private vulnerability reporting](../../security/advisories/new) instead of opening a public issue.

## Scope

- This repo's Terraform configuration and the AWS/Azure resources it defines

Out of scope: vulnerabilities in the underlying Terraform providers, AWS Interconnect, or Azure Multicloud Interconnect themselves — please report those to their respective maintainers/vendors.
