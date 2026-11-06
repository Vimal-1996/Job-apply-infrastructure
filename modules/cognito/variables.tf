variable "name" {
  description = "Name prefix including the environment suffix, e.g. job-apply-dev."
  type        = string
}

variable "allowed_emails" {
  description = "Only these emails may have an account (enforced by a pre-sign-up Lambda)."
  type        = list(string)
}

variable "callback_urls" {
  type    = list(string)
  default = ["http://localhost:5173/callback"]
}

variable "logout_urls" {
  type    = list(string)
  default = ["http://localhost:5173/"]
}

variable "groups" {
  description = <<-EOT
    Cognito groups (surface as the cognito:groups claim). admin/user are roles
    used for RBAC; inactive/deleted mark accounts an admin has deactivated or
    soft-deleted in the app, which the API then refuses with a
    "contact your administrator" message.
  EOT
  type        = map(string)
  default = {
    admin    = "Full access"
    user     = "Standard access"
    inactive = "Deactivated by an administrator; sign-in is refused"
    deleted  = "Deleted by an administrator (soft delete); sign-in is refused"
  }
}

variable "google_client_id" {
  description = "Google OAuth client ID. Leave empty to disable Google sign-in."
  type        = string
  default     = ""
}

variable "google_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "deletion_protection" {
  type    = bool
  default = false
}
