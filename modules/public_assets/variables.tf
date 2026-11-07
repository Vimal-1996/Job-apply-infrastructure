variable "name" {
  description = "Name prefix including the environment suffix, e.g. job-apply-dev."
  type        = string
}

variable "force_destroy" {
  description = "Allow deleting the bucket with its files (intentional teardown only)."
  type        = bool
  default     = false
}
