# Hosting Alternatives and Costs

Status: research only — no migration planned
Date: 2026-06-12 (all prices verified against provider pricing pages on this date; they drift, re-verify before acting)

## Summary

Exploration of what it would take to move koom's backend off the current Vercel + Supabase + Cloudflare R2 combination and onto a single provider (AWS, DigitalOcean, Render, or GCP), and what each option costs at koom's single-tenant scale.

Two conclusions:

1. **The backend is already nearly cloud-agnostic by design.** The production footprint is a Next.js server, plain Postgres (the Supabase lockdown means we use none of Supabase's API surface — just a `pg` pool), and an S3-compatible blob store accessed through `@aws-sdk/client-s3` with an env-driven endpoint. Ollama runs on the desktop client and never moves. The entire deploy contract is seven env vars: `DATABASE_URL`, the five `R2_*` values, `KOOM_PUBLIC_BASE_URL`, plus `KOOM_ADMIN_SECRET`.
2. **Every move costs real money versus today's ~$0/mo.** Floors range from ~$14/mo (Render) to ~$72/mo (canonical AWS). The spread is driven by fixed networking tax and video egress pricing, not by anything that scales with our usage.

## What portability actually requires

The work that buys cross-cloud freedom is small and provider-independent:

1. **Containerize the web app** — `output: 'standalone'` in `next.config.ts` plus a ~20-line Dockerfile. The artifact then runs on ECS, Render, Cloud Run, or a droplet unchanged.
2. **Genericize the storage config** — the code already treats R2 as generic S3; renaming `R2_*` → `S3_*`-style vars makes that explicit. The public serving path is already abstracted behind `R2_PUBLIC_BASE_URL`.
3. **Decouple migrations from the Supabase link** — the Supabase CLI supports `db push --db-url postgresql://...` against any Postgres, or switch to a generic runner (dbmate, golang-migrate) over the same timestamped SQL files. One caveat: `20260409193257_lock_down_public_access.sql` references Supabase-specific roles (`anon`, `authenticated`) and drops Supabase-installed extensions/triggers; on non-Supabase Postgres it needs guarding (e.g. `DO` blocks checking `pg_roles`) or the migration history forks at the move.
4. **Per-target Terraform root modules** — Terraform abstracts APIs, not clouds; don't attempt one cloud-agnostic module. Each target is a thin module satisfying the same env-var contract.

Steps 1–3 are roughly a day of work and are the real portability investment; the per-cloud Terraform is easy afterward.

**Storage does not have to move with compute.** R2 is just an HTTPS endpoint with zero egress fees. A koom running on Render, a droplet, or AWS can keep the existing R2 bucket unchanged — and for a video-serving app, probably should.

## Terraform shapes per provider

### AWS (canonical VPC stack)

~30–35 resources, of which maybe five are koom-specific:

- **Networking:** `aws_vpc`, 2 public + 2 private subnets across two AZs (RDS subnet groups require two), internet gateway, NAT gateway + EIP (or VPC endpoints for ECR/S3/CloudWatch to skip NAT), route tables.
- **Database:** `aws_db_subnet_group`, `aws_db_instance` (db.t4g.micro single-AZ), security group allowing 5432 from the app SG only.
- **Storage/serving:** `aws_s3_bucket` + CORS config (presigned uploads need it), CloudFront distribution + origin access control playing the role of R2's `.r2.dev` URL.
- **App:** ECR repo, ECS cluster + task definition + Fargate service, ALB + target group + HTTPS listener, ACM cert + validation, Route53 record, CloudWatch log group, IAM task-execution/task roles, secrets in Secrets Manager or SSM.

Cheaper AWS variants: App Runner replaces ALB + Fargate + most networking (~$5/mo idle since idle instances bill memory only); or one EC2 t4g.micro running everything droplet-style (~$8/mo).

### DigitalOcean (droplet)

8–10 resources via the official `digitalocean` provider:

- `digitalocean_droplet` with cloud-init `user_data` installing Docker and running the container behind Caddy (automatic Let's Encrypt replaces the entire ACM/ALB apparatus).
- `digitalocean_firewall` (80/443/SSH), `digitalocean_reserved_ip`, `digitalocean_domain`/`digitalocean_record`.
- Postgres: `digitalocean_database_cluster` ($15/mo managed) or a second container on the droplet with a volume — defensible at single-tenant scale.
- Storage: keep R2, or `digitalocean_spaces_bucket` (S3-compatible; same five env vars, different values).

### Render

Terraform provider exists (or native `render.yaml` blueprint): Docker web service + managed Postgres; Render owns TLS and networking. No object storage product — R2/S3 stays regardless.

### GCP

Cloud Run service + Cloud SQL Postgres + GCS bucket. Shaped wrong for this workload — see costs.

## Cost comparison (June 2026)

Minimum viable, always-on, single-tenant:

| Stack                                           | Compute                                            | Postgres                       | Object storage                   | **Floor/mo**                          |
| ----------------------------------------------- | -------------------------------------------------- | ------------------------------ | -------------------------------- | ------------------------------------- |
| **Current** (Vercel Hobby + Supabase Free + R2) | $0                                                 | $0                             | $0                               | **~$0**                               |
| **Render** + R2 kept                            | $7 Starter                                         | ~$7 smallest paid              | n/a                              | **~$14**                              |
| **DigitalOcean** all-in                         | $6 droplet                                         | $15 managed (or $0 on-droplet) | $5 Spaces (250GB + 1TB transfer) | **~$26** (~$11–17 self-hosting PG)    |
| **GCP** all-in                                  | ~$27 Cloud Run min-instances=1 (~$0 scale-to-zero) | ~$11–13 Cloud SQL db-f1-micro  | GCS pennies                      | **~$40** warm / ~$13 with cold starts |
| **AWS** canonical                               | $9 Fargate (0.25 vCPU/0.5GB)                       | $14 RDS t4g.micro + 20GB gp3   | S3 + CloudFront ~pennies         | + $33 NAT + $16 ALB = **~$72**        |

Per-provider notes:

- **Current stack caveats:** Supabase Free pauses projects after 7 days of inactivity (Pro: $25/mo); R2 free tier is 10GB storage, then $0.015/GB-mo (100GB of video ≈ $1.35/mo); Vercel Hobby is personal-use-only by ToS, which a single-tenant personal tool satisfies.
- **AWS:** the useful parts (Fargate + RDS ≈ $23) are cheap; the canonical architecture surrounds them with ~$49/mo of fixed plumbing (NAT $33, ALB $16) that costs more than the application. App Runner / VPC-endpoint / public-subnet variants land at ~$20–30/mo.
- **DigitalOcean:** cleanest mid-point — every line item does real work, no networking tax. Droplet bandwidth (1TB on the $6 tier) plus Spaces' included 1TB make video egress effectively free at our scale.
- **Render:** cheapest managed option, but free tiers are traps (web services spin down after 15 min; free Postgres is deleted after 30 days). Pricing was sourced from third-party trackers because render.com/pricing didn't fetch cleanly — re-verify before relying on exact figures.
- **GCP:** Cloud Run is priced for bursty request-driven services; always-warm costs ~$27/mo for half a vCPU, scale-to-zero means 1–2s cold starts on share-link visits. GCS egress ($0.12/GB from byte one) is the worst of the bunch for serving video.

## Egress is the sleeper variable

For a screen-recording app, what providers charge to serve video bytes dominates long-term cost shape:

| Provider      | Video egress                                                                     |
| ------------- | -------------------------------------------------------------------------------- |
| Cloudflare R2 | $0, forever, any volume                                                          |
| DigitalOcean  | 1TB bundled with Spaces ($5) + 1TB with the $6 droplet; $0.01/GB after           |
| AWS           | S3 direct $0.09/GB; CloudFront permanent free tier covers 1TB/mo, then $0.085/GB |
| GCP (GCS)     | $0.12/GB from the first byte                                                     |

Hence the strongest cross-cloud move, financially and architecturally: **keep blobs on R2 no matter where compute lives.**

## Sources

Pricing verified 2026-06-12 against: vercel.com/pricing, supabase.com/pricing, developers.cloudflare.com/r2/pricing, aws.amazon.com/{fargate,rds,vpc,elasticloadbalancing,apprunner}/pricing, digitalocean.com/pricing, docs.digitalocean.com/products/spaces/details/pricing, cloud.google.com/{run,sql,storage}/pricing. Render figures via third-party trackers (costbench.com) — see caveat above.
