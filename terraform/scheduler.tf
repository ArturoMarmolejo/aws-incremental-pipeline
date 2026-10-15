data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingest_scheduler" {
  name               = "arturo-gbfs-ingest-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "ingest_invoke" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.ingest.arn]
  }
}

resource "aws_iam_role_policy" "ingest_invoke" {
  name   = "InvokeGbfsIngest"
  role   = aws_iam_role.ingest_scheduler.id
  policy = data.aws_iam_policy_document.ingest_invoke.json
}

resource "aws_scheduler_schedule" "ingest" {
  name                = "arturo-gbfs-ingest-5min"
  schedule_expression = "rate(5 minutes)"
  state               = var.ingest_schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.ingest.arn
    role_arn = aws_iam_role.ingest_scheduler.arn
  }
}

variable "ingest_schedule_enabled" {
  type    = bool
  default = false
}
