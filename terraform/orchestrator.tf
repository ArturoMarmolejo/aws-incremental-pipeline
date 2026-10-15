variable "redshift_workgroup" {
  type    = string
  default = "arturo-gold-wg"
}

variable "redshift_database" {
  type    = string
  default = "dev"
}

# Read-only lookup of the existing workgroup (needed for its ARN)
data "aws_redshiftserverless_workgroup" "gold" {
  workgroup_name = var.redshift_workgroup
}

data "archive_file" "orchestrator" {
  type        = "zip"
  output_path = "${path.module}/orchestrator.zip"

  source {
    content  = file("${path.module}/../lambda/plan_batch.py")
    filename = "plan_batch.py"
  }
  source {
    content  = file("${path.module}/../lambda/batch_steps.py")
    filename = "batch_steps.py"
  }
  source {
    content  = file("${path.module}/../sql/process_batch.sql")
    filename = "sql/process_batch.sql"
  }
  source {
    content  = file("${path.module}/../sql/data_quality_checks.sql")
    filename = "sql/data_quality_checks.sql"
  }
  source {
    content  = file("${path.module}/../sql/complete_batch.sql")
    filename = "sql/complete_batch.sql"
  }
  source {
    content  = file("${path.module}/../sql/fail_batch.sql")
    filename = "sql/fail_batch.sql"
  }
}

resource "aws_iam_role" "orchestrator" {
  name = "arturo-gbfs-orchestrator-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "orchestrator_logs" {
  role       = aws_iam_role.orchestrator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "orchestrator_redshift" {
  name = "GbfsRedshiftDataApi"
  role = aws_iam_role.orchestrator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "redshift-data:ExecuteStatement",
          "redshift-data:BatchExecuteStatement",
          "redshift-data:DescribeStatement",
          "redshift-data:GetStatementResult"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "redshift-serverless:GetCredentials"
        Resource = data.aws_redshiftserverless_workgroup.gold.arn
      }
    ]
  })
}

resource "aws_lambda_function" "orchestrator" {
  function_name    = "arturo-gbfs-orchestrator"
  role             = aws_iam_role.orchestrator.arn
  runtime          = "python3.12"
  handler          = "batch_steps.handler"
  filename         = data.archive_file.orchestrator.output_path
  source_code_hash = data.archive_file.orchestrator.output_base64sha256
  timeout          = 300
  memory_size      = 256

  environment {
    variables = {
      WORKGROUP = var.redshift_workgroup
      DATABASE  = var.redshift_database
    }
  }
}
