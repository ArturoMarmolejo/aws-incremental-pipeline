data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gbfs_glue" {
  name               = "arturo-gbfs-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

resource "aws_iam_role_policy_attachment" "gbfs_glue_service" {
  role       = aws_iam_role.gbfs_glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "gbfs_glue_s3" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.bucket_name}"]
  }
  statement {
    sid       = "ReadBronzeAndScripts"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.bucket_name}/bronze/gbfs/*", "arn:aws:s3:::${var.bucket_name}/scripts/*"]
  }
  statement {
    sid       = "ReadWriteSilverAndTemp"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.bucket_name}/silver/gbfs/*", "arn:aws:s3:::${var.bucket_name}/glue-temp/*"]
  }
}

resource "aws_iam_role_policy" "gbfs_glue_s3" {
  name   = "GbfsGlueS3Access"
  role   = aws_iam_role.gbfs_glue.id
  policy = data.aws_iam_policy_document.gbfs_glue_s3.json
}

resource "aws_s3_object" "bronze_to_silver" {
  bucket = var.bucket_name
  key    = "scripts/gbfs_bronze_to_silver.py"
  source = "${path.module}/../glue/bronze_to_silver.py"
  etag   = filemd5("${path.module}/../glue/bronze_to_silver.py")
}

resource "aws_glue_job" "bronze_to_silver" {
  name              = "arturo-gbfs-bronze-to-silver"
  role_arn          = aws_iam_role.gbfs_glue.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 15
  max_retries       = 0

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.bucket_name}/${aws_s3_object.bronze_to_silver.key}"
  }

  default_arguments = {
    "--bucket"                           = var.bucket_name
    "--TempDir"                          = "s3://${var.bucket_name}/glue-temp/"
    "--enable-continuous-cloudwatch-log" = "true"
  }
}

resource "aws_s3_object" "silver_to_redshift" {
  bucket = var.bucket_name
  key    = "scripts/gbfs_silver_to_redshift.py"
  source = "${path.module}/../glue/silver_to_redshift.py"
  etag   = filemd5("${path.module}/../glue/silver_to_redshift.py")
}

resource "aws_glue_job" "silver_to_redshift" {
  name              = "arturo-gbfs-silver-to-redshift"
  role_arn          = aws_iam_role.gbfs_glue.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 15
  max_retries       = 0
  connections       = ["arturo-redshift-vpc"]

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.bucket_name}/${aws_s3_object.silver_to_redshift.key}"
  }

  default_arguments = {
    "--bucket"                           = var.bucket_name
    "--connection_name"                  = "arturo-redshift-vpc"
    "--TempDir"                          = "s3://${var.bucket_name}/glue-temp/"
    "--enable-continuous-cloudwatch-log" = "true"
  }
}
