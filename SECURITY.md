# iBacalao Homework Automation security policy

## Reporting a vulnerability

GitHub private vulnerability reporting is not enabled yet. GitHub currently makes this setting available for public repositories, so maintainers will enable and verify it immediately after the public release. See [GitHub's setup instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).

Once enabled, use GitHub **Security → Advisories → Report a vulnerability**. Until that route is confirmed available, email `support@ibacalao.com` with the subject `Private security report` and ask for a secure reporting route. Do not include vulnerability details, tokens, API keys, logs, proof-of-concept code, or student data in that initial message. Never post vulnerability details publicly.

Scope: this local worker's handling of model keys, long-lived agent tokens, job-scoped claim tokens, assignment content, network requests, and generated DOCX files. The paired iBacalao server must validate DOCX packages and verify account ownership and the current claim before storing drafts. Self-hosted servers must enforce the same checks.
