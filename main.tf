data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "template_file" "elasticsearch_access_policies" {
  template = "${file("${path.module}/elasticsearch_access_policies.json")}"

  vars {
    account_id       = "${data.aws_caller_identity.current.account_id}"
    identity_role_id = "${aws_iam_role.es_cognito_identity_role.arn}"
  }
}

resource "aws_elasticsearch_domain" "elasticsearch" {
  access_policies       = "${data.template_file.elasticsearch_access_policies.rendered}"
  domain_name           = "${var.name}"
  elasticsearch_version = "${var.es_version}"

  advanced_options {
    "rest.action.multi.allow_explicit_index" = "true"
  }

  cluster_config {
    instance_count = "${var.es_instance_count}"
    instance_type  = "${var.es_instance_type}"
  }

  ebs_options {
    ebs_enabled = true
    volume_size = "${var.es_volume_size}"
    volume_type = "gp2"
  }

  cognito_options {
    enabled          = true
    user_pool_id     = "${aws_cognito_user_pool.user_pool.id}"
    identity_pool_id = "${aws_cognito_identity_pool.identity_pool.id}"
    role_arn         = "${aws_iam_role.es_cognito_role.arn}"
  }

  tags = "${var.tags}"
}

resource "aws_iam_role" "lambda_role" {
  assume_role_policy = "${file("${path.module}/lambda_policy.json")}"
  name               = "${var.name}-lambda-role"
}

data "aws_iam_policy_document" "lambda_role" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    actions = [
      "es:ESHttp*",
    ]

    resources = ["arn:aws:es:*:*:*"]
  }
}

resource "aws_iam_policy" "lambda_role" {
  name   = "${var.name}-lambda-policy"
  policy = "${data.aws_iam_policy_document.lambda_role.json}"
}

resource "aws_iam_role_policy_attachment" "lambda_role" {
  policy_arn = "${aws_iam_policy.lambda_role.arn}"
  role       = "${aws_iam_role.lambda_role.name}"
}

data "archive_file" "lambdas_src" {
  output_path = "${path.module}/lambdas_src.zip"
  source_dir  = "${path.module}/lambdas_src"
  type        = "zip"
}

resource "aws_lambda_function" "stream_logs_function_lambda" {
  filename         = "${data.archive_file.lambdas_src.output_path}"
  function_name    = "${var.name}-stream"
  handler          = "stream_logs.handler"
  publish          = true
  role             = "${aws_iam_role.lambda_role.arn}"
  runtime          = "nodejs8.10"
  source_code_hash = "${data.archive_file.lambdas_src.output_base64sha256}"
  timeout          = 300

  tags = "${var.tags}"

  environment {
    variables {
      ES_ENDPOINT        = "${aws_elasticsearch_domain.elasticsearch.endpoint}"
      INDEX_NAME_PATTERN = "${var.indices_name_pattern}"
    }
  }
}

resource "aws_lambda_function" "clean_es_indices_function_lambda" {
  count            = "${var.clean_old_indices ? 1 : 0}"
  filename         = "${data.archive_file.lambdas_src.output_path}"
  function_name    = "${var.name}-clean-es-indices"
  handler          = "clean_es_indices.handler"
  publish          = true
  role             = "${aws_iam_role.lambda_role.arn}"
  runtime          = "nodejs8.10"
  source_code_hash = "${data.archive_file.lambdas_src.output_base64sha256}"
  timeout          = 300

  tags = "${var.tags}"

  environment {
    variables {
      DELETE_AFTER_IN_DAYS = "${var.clean_indices_after}"
      ES_ENDPOINT          = "${aws_elasticsearch_domain.elasticsearch.endpoint}"
      INDEX_NAME_PATTERN   = "${var.indices_name_pattern}"
    }
  }
}

resource "aws_cloudwatch_event_rule" "clean_es_indices" {
  count               = "${var.clean_old_indices ? 1 : 0}"
  description         = "Triggers Lambda to verify old indices to clean"
  name                = "${var.name}-clean-es"
  schedule_expression = "cron(0 0 * * ? *)"
}

resource "aws_cloudwatch_event_target" "clean_es_indices_event_target" {
  arn       = "${aws_lambda_function.clean_es_indices_function_lambda.arn}"
  count     = "${var.clean_old_indices ? 1 : 0}"
  rule      = "${aws_cloudwatch_event_rule.clean_es_indices.name}"
  target_id = "clean_es_indices"
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_clean_es_indices" {
  action        = "lambda:InvokeFunction"
  count         = "${var.clean_old_indices ? 1 : 0}"
  function_name = "${aws_lambda_function.clean_es_indices_function_lambda.function_name}"
  principal     = "events.amazonaws.com"
  source_arn    = "${aws_cloudwatch_event_rule.clean_es_indices.arn}"
  statement_id  = "allow-cloudwatch-to-call-clean-es-indices"
}

resource "aws_cognito_user_pool" "user_pool" {
  name = "${var.name}-users"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  tags = "${var.tags}"
}

resource "aws_cognito_user_pool_domain" "domain" {
  domain       = "${var.name}"
  user_pool_id = "${aws_cognito_user_pool.user_pool.id}"
}

resource "aws_cognito_identity_pool" "identity_pool" {
  allow_unauthenticated_identities = false
  identity_pool_name               = "${replace(var.name, "-", " ")} identities"

  lifecycle {
    ignore_changes = [
      "cognito_identity_providers",
    ]
  }
}

resource "aws_iam_role" "es_cognito_role" {
  assume_role_policy = "${file("${path.module}/cognito_access_for_es_role.json")}"
  description        = "Amazon Elasticsearch role for Kibana authentication"
  name               = "${var.name}-cognito-access-for-es-role"
}

resource "aws_iam_role_policy_attachment" "es_cognito_role_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonESCognitoAccess"
  role       = "${aws_iam_role.es_cognito_role.name}"
}

data "template_file" "es_cognito_identity_role" {
  template = "${file("${path.module}/es_cognito_identity_role.json")}"

  vars {
    identity_pool_id = "${aws_cognito_identity_pool.identity_pool.id}"
  }
}

resource "aws_iam_role" "es_cognito_identity_role" {
  assume_role_policy = "${data.template_file.es_cognito_identity_role.rendered}"
  name               = "${var.name}-es-cognito-identity"
}

resource "aws_iam_policy" "es_cognito_identity_policy" {
  name   = "${var.name}-es-cognito-identity"
  policy = "${file("${path.module}/es_cognito_identity_policy.json")}"
}

resource "aws_cognito_identity_pool_roles_attachment" "identity_pool" {
  identity_pool_id = "${aws_cognito_identity_pool.identity_pool.id}"

  roles {
    authenticated = "${aws_iam_role.es_cognito_identity_role.arn}"
  }
}

resource "aws_iam_role_policy_attachment" "es_cognito_identity_role_attachment" {
  policy_arn = "${aws_iam_policy.es_cognito_identity_policy.arn}"
  role       = "${aws_iam_role.es_cognito_identity_role.name}"
}
