# cloud-dev-stack

A disposable, browser-accessible dev environment on AWS (sa-east-1, São Paulo): code-server (VS Code) plus a
terminal, reachable only over your Tailscale tailnet. One click in the Actions tab creates it, one
click destroys it. Your code lives in GitHub; nothing on the box is meant to persist.

```
bootstrap/   applied ONCE by hand, never destroyed: state bucket, GitHub OIDC, IAM roles, budget alert
infra/       the disposable stack (VPC, EC2, IAM instance role), applied/destroyed by the workflow
scripts/     user-data.sh (boot script) and extensions.txt (code-server extensions)
.github/workflows/
  deploy.yml           apply/destroy on demand, plan on pull requests
  nightly-destroy.yml  scheduled safety-net destroy
```

## 1. One-time setup

### 1a. Bootstrap (from your machine, with AWS admin credentials)

The state bucket, OIDC provider and budget live in `us-east-1` (`region`); the dev box runs in
`sa-east-1` (`infra_region`, which scopes the deploy role). The Terraform backend stays in
`us-east-1` because that is where the bucket is.

```bash
cd bootstrap
terraform init
terraform apply -var 'budget_email=you@example.com'
terraform output        # note state_bucket, deploy_role_arn, plan_role_arn
```

`github_sub_prefix` defaults to this repo's immutable OIDC subject
(`repo:gustrovalim@53983036/cloud-dev-stack@1411121301`). Repos created after 2026-07-15 use this
format. Verify with `gh api repos/gustrovalim/cloud-dev-stack/actions/oidc/customization/sub`.

Bootstrap state stays local (gitignored). Keep a copy somewhere safe; it holds no secrets.

### 1b. The two secrets (SSM Parameter Store, created by hand, never in Terraform)

```bash
aws ssm put-parameter --region sa-east-1 --type SecureString \
  --name /devbox/code-server-password --value 'CHOOSE-A-LONG-PASSPHRASE'

aws ssm put-parameter --region sa-east-1 --type SecureString \
  --name /devbox/tailscale-authkey --value 'tskey-auth-XXXXXXXX'
```

The parameters live in `sa-east-1`, next to the instance (SSM is regional). Both use the default `aws/ssm` KMS key. Use `--overwrite` to rotate. Tailscale auth keys expire
after at most 90 days, so you will need to create a new one and overwrite the parameter.

### 1c. Tailscale admin console

1. **DNS**: enable MagicDNS and **HTTPS Certificates** (admin console > DNS). Without HTTPS
   certificates `tailscale serve` cannot provide HTTPS and the browser clipboard will not work.
2. **ACL tag**: in the access controls file add the tag, for example:
   ```json
   "tagOwners": { "tag:devbox": ["autogroup:admin"] }
   ```
   and make sure your policy lets your own devices reach `tag:devbox` on port 443.
3. **Auth key** (Settings > Keys > Generate auth key): enable **Ephemeral**, add tag
   `tag:devbox`, enable **Pre-approved** if device approval is on. Reusable is fine (the key is
   used every time you apply). Put the key into the SSM parameter above.
4. Note your tailnet DNS name (for example `tail1234.ts.net`).

### 1d. GitHub repo settings

Settings > Secrets and variables > Actions > **Variables** (none of these are secrets):

| Variable | Value |
|---|---|
| `TF_STATE_BUCKET` | bootstrap output `state_bucket` |
| `AWS_DEPLOY_ROLE_ARN` | bootstrap output `deploy_role_arn` |
| `AWS_PLAN_ROLE_ARN` | bootstrap output `plan_role_arn` |
| `TAILNET_DNS_NAME` | for example `tail1234.ts.net` |
| `NIGHTLY_DESTROY` | optional; set to `false` to disable the nightly destroy |

Because the repo is public, also set:

- Settings > Actions > General > **Fork pull request workflows**: require approval for all outside
  collaborators. Do not enable "send secrets/write tokens to fork PRs".
- Settings > Actions > General > Workflow permissions: **read repository contents** by default.
- Settings > Branches (or Rulesets): protect `main` (require PRs, block force pushes). The deploy
  role trusts any workflow run on `main`, so write access to `main` is the real key to the AWS
  account.
- No environment protection rules are needed. If you add an environment to a job, the OIDC `sub`
  changes to the `environment:` form and the trust policy in `bootstrap/` must be updated.

## 2. Daily use

- **Create**: Actions > deploy > Run workflow > `apply`. The job summary shows the URL.
  Wait 3-5 minutes for the boot script.
- **Destroy**: Actions > deploy > Run workflow > `destroy`. Safe to re-run if it fails partway.
- **Nightly**: `nightly-destroy.yml` runs at 05:00 UTC. Change the `cron` line in that file, or set
  the repo variable `NIGHTLY_DESTROY=false`, or disable the workflow in the Actions tab.
  GitHub pauses scheduled workflows after 60 days without repo activity; check now and then.
- **Pull requests** run `fmt`, `validate` and a read-only `plan` (no apply).

Run deploy workflows from `main` only (the deploy role rejects other refs).

## 3. Connecting

- Open `https://devbox.<your-tailnet>.ts.net` from any device signed in to Tailscale, enter the
  code-server password. On the Tab S9 FE install the Tailscale Android app, then in Chrome use
  menu > **Install app** to get the PWA.
- Terminal: the integrated terminal in code-server, or a second path with Session Manager (needs
  the AWS CLI and session-manager-plugin, or the AWS console > EC2 > Connect > Session Manager):
  ```bash
  aws ssm start-session --region sa-east-1 --target <instance_id>
  ```
- Boot log: `sudo tail -f /var/log/devbox-init.log` (over Session Manager).
- The box has no inbound security-group rules and no SSH. The instance has a public IP only for
  outbound traffic (there is no NAT gateway).

Installed: git, Docker, Python 3.13 (`python3.13`; system `python3` stays 3.9), Corretto JDK 21,
AWS CLI v2, GitHub CLI, code-server, Tailscale. Run `gh auth login` on the box for your repos.
code-server pulls extensions from Open VSX, not the Microsoft Marketplace.

## 4. Security notes

- No long-lived AWS keys. GitHub OIDC only.
- Deploy role trust policy (exact, from `bootstrap/main.tf`):
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:gustrovalim@53983036/cloud-dev-stack@1411121301:ref:refs/heads/main"
        }
      }
    }]
  }
  ```
  The plan role is identical except `sub` is `...@1411121301:pull_request` and it is read-only.
- Broad grants that cannot be avoided: the deploy role has `ec2:*` limited to sa-east-1 (`infra_region`), because
  VPC/EC2 create and delete actions largely do not support resource-level restriction. IAM is
  limited to `devbox-*` roles/profiles, only the SSM core policy can be attached, and `PassRole`
  works only for EC2. The role cannot read the two secret parameters.
- The code-server password sits in a 0600 `config.yaml` on the box. Terraform never sees it.
- IMDSv2 only, hop limit 1 (containers cannot reach instance credentials; raise to 2 in
  `infra/main.tf` if you need that).
- State contains no secrets, but user data (visible in state and the EC2 console) holds only
  parameter names, never values.

## 5. Cost notes (sa-east-1, approximate, check current pricing)

- t3.large on-demand in sa-east-1 is about $0.134/hour (AWS Pricing API, 2026-10), so roughly $3.2/day if left running (us-east-1 would be $0.083/hour, but adds ~140 ms of latency from Brazil); 50 GB gp3 is about
  $4/month while the instance exists (it goes away on destroy).
- No NAT gateway and no load balancer. The public IPv4 address costs about $0.005/hour.
- State bucket and the budget alert cost almost nothing (the first two budgets are free).
- `bootstrap/` sets a monthly budget (default $30) with alerts at 50%, 80% actual and 100% forecast.

## 6. If something goes wrong

- Destroy failed: re-run the destroy. If a run was cancelled and left a lock, the message names a
  `.tflock` object in the state bucket; delete it with `aws s3 rm` after confirming no run is active.
- Page does not load: check Tailscale is connected on your device, then read the boot log. Common
  causes: HTTPS certificates not enabled, auth key expired or tag not in `tagOwners`.
- Hostname became `devbox-1`: the previous node had not left the tailnet; remove the stale one in the
  Tailscale admin console and re-apply (or use the new name).
