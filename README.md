# ci-workflows

Shared GitHub Actions for DevConex repos. One reusable workflow deploys the calling repo to Vercel, using the repo name as the Vercel project name (created on first deploy, reused afterwards).

## Layout

- `.github/workflows/vercel-deploy.yml`: the reusable workflow
- `examples/deploy.yml`: caller file, copy to `.github/workflows/deploy.yml` in a site repo
- `examples/vercel.json`: Next.js config, copy to the site repo root
- `aws/setup.sh`: one-time AWS setup (OIDC provider, IAM role, SSM parameter)

## Where the secrets come from

- Vercel token: AWS SSM SecureString `/devconex/vercel/token` (created by `aws/setup.sh`), read in the "Read Vercel token from SSM" step.
- AWS credentials: none stored. GitHub OIDC gives short-lived credentials for the role.
- Vercel slug and role ARN: non-secret defaults in `vercel-deploy.yml`.
- No GitHub secrets or variables are used.

## One-time setup

1. Create a team-scoped Vercel token at https://vercel.com/account/tokens.
2. With AWS admin credentials: `bash aws/setup.sh us-east-1`.
3. Commit, push, then `git tag -f v1 && git push -f origin v1`.

## Add a site

Copy `examples/deploy.yml` to `.github/workflows/deploy.yml` and `examples/vercel.json` to the repo root. Push to `main`.

## Notes

- Push to `main` is a production deploy, pull requests are previews, manual runs work on `main` only.
- The repo must be public so private repos can call the workflow.
- Any repo in the org can assume the role (trust policy matches `repo:<org>/*`).
- Vercel Hobby is non-commercial only; client sites need a Pro team in `vercel_scope`.
- Renaming a repo creates a new Vercel project.
