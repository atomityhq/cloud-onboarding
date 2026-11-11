# ---------------------------------------------------------------------------
# (Organizations only): deploy a narrower read-only role to every
# member account with a service-managed CloudFormation StackSet.
#
# Everything here is gated by `count`, so with enable_organizations = false
# (the default) none of these resources exist.
#
# Prerequisite, once per organization, from the management account:
#   aws organizations enable-aws-service-access \
#     --service-principal member.org.stacksets.cloudformation.amazonaws.com
# ---------------------------------------------------------------------------

data "aws_organizations_organization" "current" {
  count = var.enable_organizations ? 1 : 0
}

resource "aws_cloudformation_stack_set" "member_roles" {
  count = var.enable_organizations ? 1 : 0

  name             = "AtomityMemberRoles"
  description      = "Atomity read-only role for member accounts"
  permission_model = "SERVICE_MANAGED"
  call_as          = var.stackset_call_as
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  template_body    = file("${path.module}/member_role.yaml")
  tags             = local.tags

  parameters = {
    ExternalId     = var.external_id
    AtomityRoleArn = local.atomity_principal_arn
  }

  # new accounts get the role.
  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  # Commonly needed with service-managed StackSets; otherwise the provider
  # shows a permanent diff on this attribute.
  lifecycle {
    ignore_changes = [administration_role_arn]
  }
}

# Deploy to organization, select your root OU
resource "aws_cloudformation_stack_set_instance" "member_roles" {
  count = var.enable_organizations ? 1 : 0

  stack_set_name = aws_cloudformation_stack_set.member_roles[0].name
  call_as        = var.stackset_call_as

  deployment_targets {
    organizational_unit_ids = [data.aws_organizations_organization.current[0].roots[0].id]
  }
}
