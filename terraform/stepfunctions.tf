locals {
  lambda_retry = [{
    ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
    IntervalSeconds = 5
    MaxAttempts     = 3
    BackoffRate     = 2
  }]
  # Glue jobs are idempotent (overwrite batch folder, delete-by-batch before load), so one retry is safe
  glue_retry = [{
    ErrorEquals     = ["States.TaskFailed"]
    IntervalSeconds = 60
    MaxAttempts     = 1
    BackoffRate     = 2
  }]
  to_failure = [{
    ErrorEquals = ["States.ALL"]
    ResultPath  = "$.error"
    Next        = "MarkBatchFailed"
  }]
}

resource "aws_iam_role" "sfn" {
  name = "arturo-gbfs-sfn-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "GbfsPipelineExecution"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = [aws_lambda_function.orchestrator.arn, "${aws_lambda_function.orchestrator.arn}:*"]
      },
      {
        Effect = "Allow"
        Action = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
        Resource = [
          aws_glue_job.bronze_to_silver.arn,
          aws_glue_job.silver_to_redshift.arn
        ]
      }
    ]
  })
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "arturo-gbfs-pipeline"
  role_arn = aws_iam_role.sfn.arn

  definition = jsonencode({
    Comment = "Incremental GBFS pipeline: plan, Bronze to Silver, load, build star schema, check, advance checkpoint"
    StartAt = "PlanBatch"
    States = {
      PlanBatch = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.orchestrator.arn
          Payload      = { action = "plan", input = {} }
        }
        ResultSelector = {
          "batch_id.$"     = "$.Payload.batch_id"
          "window_start.$" = "$.Payload.window_start"
          "window_end.$"   = "$.Payload.window_end"
          "skip.$"         = "$.Payload.skip"
        }
        ResultPath = "$.plan"
        Retry      = local.lambda_retry
        Catch      = [{ ErrorEquals = ["States.ALL"], Next = "PlanFailed" }]
        Next       = "AnythingToDo"
      }

      AnythingToDo = {
        Type    = "Choice"
        Choices = [{ Variable = "$.plan.skip", BooleanEquals = true, Next = "NothingToProcess" }]
        Default = "BronzeToSilver"
      }

      NothingToProcess = { Type = "Succeed" }

      BronzeToSilver = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.bronze_to_silver.name
          Arguments = {
            "--window_start.$" = "$.plan.window_start"
            "--window_end.$"   = "$.plan.window_end"
            "--batch_id.$"     = "$.plan.batch_id"
          }
        }
        ResultPath     = null
        TimeoutSeconds = 1800
        Retry          = local.glue_retry
        Catch          = local.to_failure
        Next           = "SilverToRedshift"
      }

      SilverToRedshift = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName   = aws_glue_job.silver_to_redshift.name
          Arguments = { "--batch_id.$" = "$.plan.batch_id" }
        }
        ResultPath     = null
        TimeoutSeconds = 1800
        Retry          = local.glue_retry
        Catch          = local.to_failure
        Next           = "BuildStarSchema"
      }

      BuildStarSchema = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.orchestrator.arn
          Payload      = { action = "process", "batch_id.$" = "$.plan.batch_id" }
        }
        ResultPath = null
        Retry      = local.lambda_retry
        Catch      = local.to_failure
        Next       = "DataQualityChecks"
      }

      DataQualityChecks = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.orchestrator.arn
          Payload      = { action = "dq", "batch_id.$" = "$.plan.batch_id" }
        }
        ResultPath = "$.dq"
        Retry      = local.lambda_retry
        Catch      = local.to_failure
        Next       = "AdvanceCheckpoint"
      }

      AdvanceCheckpoint = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.orchestrator.arn
          Payload      = { action = "complete", "batch_id.$" = "$.plan.batch_id" }
        }
        ResultPath = null
        Retry      = local.lambda_retry
        Catch      = local.to_failure
        Next       = "PipelineSucceeded"
      }

      PipelineSucceeded = { Type = "Succeed" }

      MarkBatchFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.orchestrator.arn
          Payload      = { action = "fail", "batch_id.$" = "$.plan.batch_id" }
        }
        ResultPath = null
        Retry      = local.lambda_retry
        Next       = "BatchFailed"
      }

      BatchFailed = {
        Type  = "Fail"
        Error = "BatchFailed"
        Cause = "A stage failed. The batch was marked FAILED and the checkpoint was not advanced."
      }

      PlanFailed = {
        Type  = "Fail"
        Error = "PlanFailed"
        Cause = "Could not plan the batch (checkpoint unreadable)."
      }
    }
  })
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline.arn
}
