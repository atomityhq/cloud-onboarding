# value to paste into Atomity.
output "role_arn" {
  description = "Paste this into the Role ARN field in Atomity."
  value       = aws_iam_role.atomity.arn
}

output "connection_details" {
  description = "Everything Atomity needs for the connection."
  value = {
    role_arn         = aws_iam_role.atomity.arn
    s3_bucket        = aws_s3_bucket.exports.bucket
    s3_prefix        = var.s3_prefix
    export_name      = var.export_name
    region           = var.aws_region
    scope            = var.enable_organizations ? "organization" : "single_account"
    organization_id  = one(data.aws_organizations_organization.current[*].id)
    member_stack_set = one(aws_cloudformation_stack_set.member_roles[*].name)
  }
}
