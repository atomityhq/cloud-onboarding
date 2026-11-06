variable "external_id" {
  type        = string
  sensitive   = true
  description = "Per-customer external ID shown in the Atomity onboarding wizard."
}

variable "s3_bucket" {
  type        = string
  description = "Name of the S3 bucket that will receive the FOCUS Data Export. Terraform creates it."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.s3_bucket))
    error_message = "Use a valid S3 bucket name: 3-63 chars, lowercase letters, digits, dots and hyphens."
  }
}

variable "aws_region" {
  type        = string
  default     = "eu-central-1"
  description = "Region of the S3 bucket that receives the Data Export."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "Use a valid AWS region name, like eu-central-1."
  }
}

variable "s3_prefix" {
  type        = string
  default     = "atomity-exports"
  description = "Prefix (folder) inside the bucket where export files are written."
}

variable "export_name" {
  type        = string
  default     = "atomity-exports"
  description = "Name of the AWS Data Export."
}

variable "time_granularity" {
  type        = string
  default     = "HOURLY"
  description = "Granularity of FOCUS 1.2 line items: HOURLY, DAILY or MONTHLY."

  validation {
    condition     = contains(["HOURLY", "DAILY", "MONTHLY"], var.time_granularity)
    error_message = "time_granularity must be HOURLY, DAILY or MONTHLY."
  }
}

variable "atomity_role_arn" {
  type        = string
  default     = "arn:aws:iam::602578933792:role/AtomityCollector"
  description = "Atomity role allowed to assume the read-only role in this account. Same for every customer."
}

variable "enable_organizations" {
  type        = bool
  default     = false
  description = "Set to true when running in an AWS Organizations management (or delegated admin) account. Also deploys the member-account role to every account via a StackSet."
}

variable "stackset_call_as" {
  type        = string
  default     = "SELF"
  description = "SELF when running in the management account, DELEGATED_ADMIN when running in a CloudFormation StackSets delegated admin account."

  validation {
    condition     = contains(["SELF", "DELEGATED_ADMIN"], var.stackset_call_as)
    error_message = "stackset_call_as must be SELF or DELEGATED_ADMIN."
  }
}

variable "delete_bucket_contents_on_destroy" {
  type        = bool
  default     = false
  description = "When true, terraform destroy also deletes every file in the billing bucket, then the bucket. Apply this setting before destroying. Leave false to keep your billing data."
}
