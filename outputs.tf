output "es_endpoint" {
  value = "${aws_elasticsearch_domain.elasticsearch.endpoint}"
}

output "es_kibana_endpoint" {
  value = "${aws_elasticsearch_domain.elasticsearch.kibana_endpoint}"
}

output "lambda_arn" {
  value = "${aws_lambda_function.stream_logs_function_lambda.arn}"
}
