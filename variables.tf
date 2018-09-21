variable "clean_indices_after" {
  default = 60
}

variable "clean_old_indices" {
  default = false
}

variable "es_instance_count" {
  default = 1
}

variable "es_instance_type" {
  default = "t2.small.elasticsearch"
}

variable "es_version" {
  default = "6.2"
}

variable "es_volume_size" {
  default = 10
}

variable "indices_name_pattern" {
  default = "'cwl-'yyyy.MM.dd"
}

variable "name" {}

variable "tags" {
  default = {}
}
