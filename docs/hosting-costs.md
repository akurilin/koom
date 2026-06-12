# Hosting Costs

Status: research only — no migration planned
Date: 2026-06-12 (all prices verified against provider pricing pages on this date; they drift, re-verify before acting)

What koom's backend costs at single-tenant scale on the current stack versus all-in on AWS, DigitalOcean, Render, or GCP. For the architecture and Terraform shape of each option, see [hosting-alternatives.md](hosting-alternatives.md).

## Summary

**Every move costs real money versus today's ~$0/mo.** Floors range from ~$14/mo (Render) to ~$72/mo (canonical AWS). The spread is driven by fixed networking tax and video egress pricing, not by anything that scales with our usage — at single-tenant scale we'd be paying for idle capacity everywhere, which is exactly what the serverless, usage-priced current stack avoids.

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
- **AWS:** the useful parts (Fargate + RDS ≈ $23) are cheap; the canonical architecture surrounds them with ~$49/mo of fixed plumbing (NAT $33, ALB $16) that costs more than the application. App Runner / VPC-endpoint / public-subnet variants land at ~$20–30/mo (App Runner bills ~$5/mo idle since idle instances pay memory only; a lone EC2 t4g.micro is ~$8/mo).
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
