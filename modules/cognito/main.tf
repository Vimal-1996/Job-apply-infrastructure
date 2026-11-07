terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  google_enabled = var.google_client_id != ""
}

# ---------- Pre-sign-up allowlist Lambda ----------
data "archive_file" "pre_signup" {
  type        = "zip"
  source_file = "${path.module}/lambda/pre_signup.py"
  output_path = "${path.module}/lambda/pre_signup.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pre_signup" {
  name               = "${var.name}-cognito-presignup"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "pre_signup_logs" {
  role       = aws_iam_role.pre_signup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allows ALLOWED_EMAILS through self sign-up / Google; admin-created users always pass.
resource "aws_lambda_function" "pre_signup" {
  function_name    = "${var.name}-cognito-presignup"
  role             = aws_iam_role.pre_signup.arn
  runtime          = "python3.12"
  handler          = "pre_signup.handler"
  filename         = data.archive_file.pre_signup.output_path
  source_code_hash = data.archive_file.pre_signup.output_base64sha256
  timeout          = 5

  environment {
    variables = { ALLOWED_EMAILS = join(",", var.allowed_emails) }
  }
}

resource "aws_lambda_permission" "cognito" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_signup.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.this.arn
}

# ---------- User pool ----------
resource "aws_cognito_user_pool" "this" {
  name                     = var.name
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  # OPTIONAL: Cognito asks for a code only from accounts with an authenticator
  # app switched on. Normal users sign in with a password; administrators
  # must have MFA switched on (the API refuses admin routes otherwise).
  mfa_configuration   = "OPTIONAL"
  deletion_protection = var.deletion_protection ? "ACTIVE" : "INACTIVE"

  software_token_mfa_configuration {
    enabled = true # TOTP authenticator apps only; no SMS (cost + SIM-swap risk)
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Sign-up for native accounts is admin-only; the Lambda also gates Google.
  # Accounts are created by the API (an admin's "Add user", or the public
  # sign-up page): Cognito generates a temporary password (valid
  # temporary_password_validity_days) and emails it with this template, so the
  # wording must fit both.
  admin_create_user_config {
    allow_admin_create_user_only = true

    invite_message_template {
      email_subject = "Your ${var.app_name} account"
      email_message = <<-EOT
        <p>Hello,</p>
        <p>Your ${var.app_name} account is ready. If you didn't sign up and weren't expecting this, you can ignore this email.</p>
        <p>Username: <b>{username}</b><br>Temporary password: <b>{####}</b></p>
        <p>Sign in at <a href="${var.app_url}">${var.app_url}</a>. You will be asked to choose a new password.</p>
        <p>The temporary password expires in 3 days. If it has expired, sign up again with the same email or ask your administrator to resend it.</p>
      EOT
      # Required by the API even though the app sends no SMS (MFA is TOTP only).
      sms_message = "Your ${var.app_name} username is {username} and temporary password is {####}"
    }
  }

  lambda_config {
    pre_sign_up = aws_lambda_function.pre_signup.arn
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }
}

resource "aws_cognito_user_group" "this" {
  for_each     = var.groups
  name         = each.key
  description  = each.value
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.name}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id

  # 2 = Managed Login (modern, brandable pages; needs the Essentials tier and a
  # branding style below). 1 = classic Hosted UI.
  managed_login_version = 2
}

# Managed Login renders "Login pages unavailable" for a client with no style.
# Start from Cognito's default look; colours/logo can be layered on later.
resource "aws_cognito_managed_login_branding" "web" {
  user_pool_id                = aws_cognito_user_pool.this.id
  client_id                   = aws_cognito_user_pool_client.web.id
  use_cognito_provided_values = true
}

# ---------- Optional Google IdP ----------
resource "aws_cognito_identity_provider" "google" {
  count         = local.google_enabled ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.this.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "openid email profile"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
  }
}

# ---------- SPA app client (code flow + PKCE, no secret) ----------
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.name}-web"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = var.callback_urls
  logout_urls                          = var.logout_urls
  supported_identity_providers         = local.google_enabled ? ["COGNITO", "Google"] : ["COGNITO"]

  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]

  enable_token_revocation       = true
  prevent_user_existence_errors = "ENABLED"

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 7
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  depends_on = [aws_cognito_identity_provider.google]
}
