# Hosting Alternatives

Status: research only — no migration planned
Date: 2026-06-12

What it would take to move koom's backend off the current Vercel + Supabase + Cloudflare R2 combination and onto a single provider (AWS, DigitalOcean, Render, or GCP). For what each option costs, see [hosting-costs.md](hosting-costs.md).

## Summary

**The backend is already nearly cloud-agnostic by design.** The production footprint is a Next.js server, plain Postgres (the Supabase lockdown means we use none of Supabase's API surface — just a `pg` pool), and an S3-compatible blob store accessed through `@aws-sdk/client-s3` with an env-driven endpoint. Ollama runs on the desktop client and never moves. The entire deploy contract is seven env vars: `DATABASE_URL`, the five `R2_*` values, `KOOM_PUBLIC_BASE_URL`, plus `KOOM_ADMIN_SECRET`.

## What portability actually requires

The work that buys cross-cloud freedom is small and provider-independent:

1. **Containerize the web app** — `output: 'standalone'` in `next.config.ts` plus a ~20-line Dockerfile. The artifact then runs on ECS, Render, Cloud Run, or a droplet unchanged.
2. **Genericize the storage config** — the code already treats R2 as generic S3; renaming `R2_*` → `S3_*`-style vars makes that explicit. The public serving path is already abstracted behind `R2_PUBLIC_BASE_URL`.
3. **Decouple migrations from the Supabase link** — the Supabase CLI supports `db push --db-url postgresql://...` against any Postgres, or switch to a generic runner (dbmate, golang-migrate) over the same timestamped SQL files. One caveat: `20260409193257_lock_down_public_access.sql` references Supabase-specific roles (`anon`, `authenticated`) and drops Supabase-installed extensions/triggers; on non-Supabase Postgres it needs guarding (e.g. `DO` blocks checking `pg_roles`) or the migration history forks at the move.
4. **Per-target Terraform root modules** — Terraform abstracts APIs, not clouds; don't attempt one cloud-agnostic module. Each target is a thin module satisfying the same env-var contract.

Steps 1–3 are roughly a day of work and are the real portability investment; the per-cloud Terraform is easy afterward.

**Storage does not have to move with compute.** R2 is just an HTTPS endpoint with zero egress fees. A koom running on Render, a droplet, or AWS can keep the existing R2 bucket unchanged — and for a video-serving app, probably should (see the egress section in [hosting-costs.md](hosting-costs.md)).

## Terraform shapes per provider

### AWS (canonical VPC stack)

~30–35 resources, of which maybe five are koom-specific:

- **Networking:** `aws_vpc`, 2 public + 2 private subnets across two AZs (RDS subnet groups require two), internet gateway, NAT gateway + EIP (or VPC endpoints for ECR/S3/CloudWatch to skip NAT), route tables.
- **Database:** `aws_db_subnet_group`, `aws_db_instance` (db.t4g.micro single-AZ), security group allowing 5432 from the app SG only.
- **Storage/serving:** `aws_s3_bucket` + CORS config (presigned uploads need it), CloudFront distribution + origin access control playing the role of R2's `.r2.dev` URL.
- **App:** ECR repo, ECS cluster + task definition + Fargate service, ALB + target group + HTTPS listener, ACM cert + validation, Route53 record, CloudWatch log group, IAM task-execution/task roles, secrets in Secrets Manager or SSM.

Cheaper AWS variants: App Runner replaces ALB + Fargate + most networking; or one EC2 t4g.micro running everything droplet-style.

### DigitalOcean (droplet)

8–10 resources via the official `digitalocean` provider:

- `digitalocean_droplet` with cloud-init `user_data` installing Docker and running the container behind Caddy (automatic Let's Encrypt replaces the entire ACM/ALB apparatus).
- `digitalocean_firewall` (80/443/SSH), `digitalocean_reserved_ip`, `digitalocean_domain`/`digitalocean_record`.
- Postgres: `digitalocean_database_cluster` (managed) or a second container on the droplet with a volume — defensible at single-tenant scale.
- Storage: keep R2, or `digitalocean_spaces_bucket` (S3-compatible; same five env vars, different values).

### Render

Terraform provider exists (or native `render.yaml` blueprint): Docker web service + managed Postgres; Render owns TLS and networking. No object storage product — R2/S3 stays regardless.

### GCP

Cloud Run service + Cloud SQL Postgres + GCS bucket. Shaped wrong for this workload — Cloud Run is priced for bursty request-driven services, and GCS egress is the worst of the bunch for serving video; see [hosting-costs.md](hosting-costs.md).
