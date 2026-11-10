data "aws_caller_identity" "current" {}

locals {
  role_name  = "AtomityReadOnly" # fixed: Atomity's side allows only this exact name
  account_id = data.aws_caller_identity.current.account_id

  # Atomity's own AWS account, the same for every customer.
  # Do not use local.account_id here: that is the customer's own account.
  atomity_account_id    = "602578933792"
  atomity_principal_arn = "arn:aws:iam::${local.atomity_account_id}:root"


  tags = {
    ManagedBy = "terraform"
    Purpose   = "atomity-cost-visibility"
  }
}

# ---------------------------------------------------------------------------
#  IAM role that Atomity assumes (trust policy + external ID)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "atomity" {
  name = local.role_name
  tags = local.tags

  assume_role_policy = templatefile("${path.module}/policies/trust.json", {
    AtomityRoleArn = local.atomity_principal_arn
    ExternalId     = var.external_id
  })
}

# ---------------------------------------------------------------------------
#  read-only permission policy
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "atomity" {
  name = "AtomityPermissions"
  role = aws_iam_role.atomity.id

  policy = templatefile("${path.module}/policies/permission.json", {
    BucketArn = aws_s3_bucket.exports.arn
  })
}

# ---------------------------------------------------------------------------
# (part 1): the bucket and the policy that lets AWS write to it
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "exports" {
  bucket = var.s3_bucket
  tags   = local.tags

  # false (default): `terraform destroy` keeps the bucket while it holds files.
  # true: destroy also deletes every file (and version) before deleting the bucket.
  force_destroy = var.delete_bucket_contents_on_destroy
}

resource "aws_s3_bucket_public_access_block" "exports" {
  bucket                  = aws_s3_bucket.exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "exports" {
  bucket     = aws_s3_bucket.exports.id
  depends_on = [aws_s3_bucket_public_access_block.exports]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EnableAWSDataExportsToWriteToS3AndCheckPolicy"
      Effect = "Allow"
      Principal = {
        Service = [
          "billingreports.amazonaws.com",
          "bcm-data-exports.amazonaws.com",
        ]
      }
      Action = [
        "s3:PutObject",
        "s3:GetBucketPolicy",
      ]
      Resource = [
        aws_s3_bucket.exports.arn,
        "${aws_s3_bucket.exports.arn}/*",
      ]
      Condition = {
        StringLike = {
          "aws:SourceAccount" = local.account_id
          "aws:SourceArn" = [
            "arn:aws:cur:us-east-1:${local.account_id}:definition/*",
            "arn:aws:bcm-data-exports:us-east-1:${local.account_id}:export/*",
          ]
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# (part 2): the FOCUS 1.2 Data Export (Parquet)
# ---------------------------------------------------------------------------
resource "aws_bcmdataexports_export" "focus" {
  provider   = aws.us_east_1 # the Data Exports API only lives in us-east-1
  depends_on = [aws_s3_bucket_policy.exports]

  export {
    name = var.export_name

    data_query {
      query_statement = trimspace(file("${path.module}/focus_query.sql"))

      table_configurations = {
        FOCUS_1_2_AWS = {
          TIME_GRANULARITY = var.time_granularity
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.exports.bucket
        s3_prefix = var.s3_prefix
        s3_region = var.aws_region # where the BUCKET lives, not the API region

        s3_output_configurations {
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
          overwrite   = "OVERWRITE_REPORT"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }
}
