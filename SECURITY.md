# Security Policy

Do not open public issues for vulnerabilities or leaked secrets.

For now, report security issues privately to the project maintainer. Include:

- A short description of the issue.
- Affected files, endpoints, or deployment mode.
- Steps to reproduce, if safe to share.
- Whether any credentials, user data, or hosted infrastructure may be exposed.

## Secret Handling

Never commit real `.env` files, APNs private keys, Supabase service-role keys,
admin secrets, Composio keys, model provider keys, Browserbase keys, or Hermes
profile secrets.

If a secret was committed or exposed, rotate it before publishing or deploying.
