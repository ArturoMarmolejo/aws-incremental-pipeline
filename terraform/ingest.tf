data "archive_file" "ingest" {
  type        = "zip"
  source_file = "${path.module}/../lambda/ingest.py"
  output_path = "${path.module}/ingest.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingest" {
  name               = "arturo-gbfs-ingest-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "ingest_logs" {
  role       = aws_iam_role.ingest.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ingest_s3" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.bucket_name}/bronze/gbfs/*"]
  }
}

resource "aws_iam_role_policy" "ingest_s3" {
  name   = "GbfsBronzeWrite"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest_s3.json
}

resource "aws_lambda_function" "ingest" {
  function_name    = "arturo-gbfs-ingest"
  role             = aws_iam_role.ingest.arn
  runtime          = "python3.12"
  handler          = "ingest.handler"
  timeout          = 30
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256

  environment {
    variables = {
      BUCKET = var.bucket_name
    }
  }
}
