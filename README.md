# Job-apply-infrastructure

AWS infrastructure (Terraform) for the Job-apply enterprise application.
Dev, staging and prod share one AWS account; resources carry an env suffix.

- `bootstrap/` – run once: S3 state bucket + GitHub OIDC provider and roles
- `modules/` – reusable modules (vpc, cognito, ...)
- `live/{dev,staging,prod}/` – environment compositions

## Bootstrap
    cd bootstrap
    terraform init
    terraform apply -var github_org=<your-github-user-or-org>
