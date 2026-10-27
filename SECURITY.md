# iBacalao Homework Automation security policy

## Reporting a vulnerability

Use GitHub **Security → Advisories → Report a vulnerability** when private reporting is available. If the form is unavailable, email `support@ibacalao.com` with the subject `Private security report` and ask for a secure reporting route. Do not include vulnerability details, tokens, API keys, logs, proof-of-concept code, or student data in that initial message.

Before making this repository public, maintainers must enable and verify a private vulnerability reporting route. Never post vulnerability details publicly, and never include real tokens, API keys, or student data in a report.

Scope: this local worker's handling of model keys, long-lived agent tokens, job-scoped claim tokens, assignment content, network requests, and generated DOCX files. The paired iBacalao server must validate DOCX packages and verify account ownership and the current claim before storing drafts. Self-hosted servers must enforce the same checks.
