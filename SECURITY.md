# iBacalao Homework Automation security policy

## Reporting a vulnerability

This repository is currently private, so GitHub's private vulnerability report form is unavailable to outside reporters. If you need to contact the maintainers, email `support@ibacalao.com` with the subject `Private security report`. Do not include vulnerability details, tokens, API keys, logs, proof-of-concept code, or student data in that initial message; ask for a secure reporting channel.

Before making the repository public or inviting outside reporters, maintainers must enable and verify GitHub private vulnerability reporting. Once available, use **Security → Advisories → Report a vulnerability**. If the form is unavailable, do not post vulnerability details publicly; use the email above only to request a secure reporting route. Never include real tokens, API keys, or student data in a report.

Scope: this bot's handling of the model key, long-lived agent token, job-scoped claim tokens, assignment content, network requests, and model output. The iBacalao server must sanitize model-generated HTML before storing or rendering it; self-hosted servers must meet the same requirement.
