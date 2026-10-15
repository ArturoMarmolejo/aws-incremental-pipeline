variable "pipeline_schedule_enabled" {
  type    = bool
  default = false
}

resource "aws_iam_role" "pipeline_scheduler" {
  name = "arturo-gbfs-pipeline-scheduler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pipeline_scheduler" {
  name = "StartGbfsPipeline"
  role = aws_iam_role.pipeline_scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.pipeline.arn
    }]
  })
}

resource "aws_scheduler_schedule" "pipeline" {
  name                         = "arturo-gbfs-pipeline-30min"
  schedule_expression          = "cron(2,32 * * * ? *)"
  schedule_expression_timezone = "UTC"
  state                        = var.pipeline_schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.pipeline.arn
    role_arn = aws_iam_role.pipeline_scheduler.arn
    input    = jsonencode({})

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
