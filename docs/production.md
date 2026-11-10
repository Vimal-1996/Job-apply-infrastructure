# Production runbook

Production lives in `live/prod` (one Terraform stack), in the same AWS account
as dev, with every resource named `job-apply-prod-*`.

## Architecture

```
Browser ──HTTPS──▶ CloudFront  https://<id>.cloudfront.net   (+ WAF)
                     ├─ /*      → S3 bucket (web app; private, origin access control)
                     └─ /api/*  → VPC origin → internal ALB → ECS Fargate "api" (2–6 tasks, 2 AZs)
                                                               ├─ RDS PostgreSQL 16 (db.t4g.micro, private, TLS only)
                                                               └─ Cognito (via NAT) — passwords, emails, MFA, admin role
```

- **No custom domain yet.** CloudFront's `*.cloudfront.net` name provides HTTPS. The load balancer has no public address.
- **Email** is Cognito's default sender: 50 emails/day, so sign-ups are capped at 30/day. Move to SES once a domain exists.
- **MFA** is required for admins only. Pool MFA is `OPTIONAL`, and admins have an authenticator switched on per account. The API refuses admin routes without it.
- **Users** are in Postgres (`app_user`), and the API checks account status there on every request. Cognito holds credentials.

## First-time setup

1. **Infrastructure:** Actions → **prod-apply** on `main`.
   - Run it with mode `plan` to review, then with mode `apply` and type `apply prod`.
   - It refuses any plan that would delete or replace the database, user pool, image registry or a bucket.
   - By hand instead: `terraform apply` from `live/prod`, with `prod.auto.tfvars` containing `alarm_email = "..."`.
   - The API has no image yet, so its tasks fail to start until step 3. That's expected.
   - Confirm the **"AWS Notification – Subscription Confirmation"** email so alerts reach you.
2. **GitHub:** the app repo needs an Environment named **`prod`**. The AWS deploy role trusts only that environment. Limit it to the `main` branch.
3. **Deploy:** in the app repo, go to Actions → **deploy-prod** → Run workflow on `main` (target `all`). It builds and pushes the image, rolls out the API, uploads the web app and smoke-tests it.
4. **First admin** (pool ID: `terraform output cognito_user_pool_id`):
   ```sh
   POOL=<pool id>; EMAIL=<admin email>
   aws cognito-idp admin-create-user --user-pool-id $POOL --username $EMAIL \
     --user-attributes Name=email,Value=$EMAIL Name=email_verified,Value=true --desired-delivery-mediums EMAIL
   aws cognito-idp admin-add-user-to-group --user-pool-id $POOL --username $EMAIL --group-name admin
   # The sign-in page only offers authenticator setup while MFA is required.
   # There are no other users yet, so require it just for this first sign-in:
   aws cognito-idp set-user-pool-mfa-config --user-pool-id $POOL --mfa-configuration ON \
     --software-token-mfa-configuration Enabled=true
   ```
   Sign in at the site URL with the emailed temporary password. Choose a new password and register an authenticator app. Then:
   ```sh
   aws cognito-idp admin-set-user-mfa-preference --user-pool-id $POOL --username $EMAIL \
     --software-token-mfa-settings Enabled=true,PreferredMfa=true
   aws cognito-idp set-user-pool-mfa-config --user-pool-id $POOL --mfa-configuration OPTIONAL \
     --software-token-mfa-configuration Enabled=true
   terraform plan   # should show no changes for the pool
   ```

## AI key (Anthropic)

The AI features (reading resumes into profiles, matching jobs, tailoring resumes) need an Anthropic API key. It lives in Secrets Manager as **`job-apply/anthropic-api-key`**, created once by hand and **not** managed by Terraform. So it survives prod teardowns, and its value never enters Terraform state or GitHub.

```sh
# Once. Reads the key without echoing it or saving it in shell history.
read -rs KEY && aws secretsmanager create-secret --name job-apply/anthropic-api-key --secret-string "$KEY"; unset KEY
```

- **prod-apply** looks the secret up by name. If it exists, ECS passes it to the API as `ANTHROPIC_API_KEY`, and only the task's start-up role may read it. If it doesn't, prod still deploys and the AI features say they're switched off.
- **Adding it later:** create the secret, then run **prod-apply** (the task definition changes) so new tasks get it.
- **Rotating it:** `aws secretsmanager put-secret-value --secret-id job-apply/anthropic-api-key --secret-string "$KEY"`, then redeploy the API (**deploy-prod**, target `api`). Running tasks keep the old value until replaced.
- **Spend:** use a separate key for prod in the Anthropic Console, with its own spend limit, so prod usage is visible and can be revoked without touching local development.

## Deploying

- **App:** Actions → **deploy-prod** on `main`. Targets: `all`, `api` or `web`.
  - It deploys exactly that commit and re-runs the tests first.
  - The API rolls out with zero downtime. If the new tasks never become healthy, ECS rolls back automatically and the workflow fails.
  - The deployed image tag is recorded in SSM `/job-apply-prod/api/image-tag`. Terraform reads it, so infrastructure changes keep the running image.
- **Infrastructure:** PR into `main`, then **prod-apply** (`plan`, then `apply`).

## Rolling back

- **API:** re-run **deploy-prod** with target `api` on an earlier commit of `main`. Its image is still in ECR, which keeps the last 30.
- **Web:** re-run with target `web` on an earlier commit. The bucket is versioned for 30 days if a file must be restored by hand.
- **Database:** automated backups, kept 7 days, allow point-in-time restore to a new instance. Deletion protection is on, and a final snapshot is taken if it's ever deleted.

## Tearing down and rebuilding

Production can be removed between releases to stop its costs (about $95–110/month), then rebuilt for the next one.

**Tear down:** Actions → **prod-teardown** → Run workflow on `main`, then type `destroy prod`. The workflow:
- does nothing if production isn't running;
- relaxes the deletion protections, checking that this step only changes settings;
- destroys everything, checking that plan only deletes;
- removes the log groups AWS created itself, and fails if anything billable is left.

By hand (from `live/prod`), the same thing is: save and apply `terraform plan -var allow_teardown=true -out=relax.tfplan`, then `terraform plan -destroy -var allow_teardown=true -out=destroy.tfplan`. Don't run the first step when `terraform state list` is empty: it would build production.
Everything goes, **including the database and the Cognito user pool with all users**. Take a manual RDS snapshot first if the data matters.

**Rebuild:** follow *First-time setup* above. **prod-apply** always runs with the protections on. Then run **deploy-prod** on `main` and create the first admin.
- **New URL:** the CloudFront address changes on every rebuild. Cognito, the API and the deploy settings pick it up automatically. Share the new URL from `terraform output url`.
- **New user pool:** the pool is new and empty, so users from a previous build are gone.

## Watching it

- **Alerts** (SNS → email): API 5xx errors, unhealthy containers, slow responses (p95 > 2 s), API or database CPU, low database storage, database connections, and site-wide 5xx rate.
- **Logs:** CloudWatch `/ecs/job-apply-prod-api`, plus Postgres logs (statements over 500 ms are logged). WAF metrics are in the `job-apply-prod-edge` web ACL.

## Costs (approximate, before traffic)

| Item | Monthly |
|---|---|
| NAT gateway | ~$33 + data |
| Load balancer | ~$18 |
| 2 Fargate tasks (0.25 vCPU, 0.5 GB) | ~$18 |
| RDS db.t4g.micro + 20 GB gp3 | ~$15 |
| WAF (web ACL + rules) | ~$10 + requests |
| CloudFront, S3, Secrets Manager, logs | a few dollars |

## Later

- **Custom domain:** ACM certificate (us-east-1) and alias on the distribution; add the new URL to the Cognito callback and logout URLs, `CORS_ORIGINS` and the `web/url` setting.
- **SES email:** verify the domain with DKIM, request production access, and point the pool's email configuration at SES. That removes the 50-emails-a-day limit.
- **In-app MFA enrollment,** so admins added later can register an authenticator without the first-admin procedure above.
- **Database user for the app:** the API currently uses the RDS master user (from Secrets Manager). Create a least-privilege role.
- **Multi-AZ database** when downtime during maintenance or a zone failure becomes unacceptable.
