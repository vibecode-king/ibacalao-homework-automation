# iBacalao Homework Automation security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: **Security → Advisories → Report a vulnerability**. If the form is unavailable, email `support@ibacalao.com` with the subject `Private security report` and ask for a secure reporting route. Do not include vulnerability details, tokens, API keys, logs, proof-of-concept code, or student data in that initial message.

Never post vulnerability details publicly, and never include real tokens, API keys, or student data in a report.

Scope: this bot's handling of the model key, long-lived agent token, job-scoped claim tokens, assignment content, network requests, and model output. The iBacalao server must sanitize model-generated HTML before storing or rendering it; self-hosted servers must meet the same requirement.
