# iBacalao Homework Automation security policy

## Reporting a vulnerability

Before inviting contributors or users to report security issues, maintainers should enable and verify GitHub private vulnerability reporting in the repository settings. Once enabled, use **Security → Advisories → Report a vulnerability** to send a private report. Do not open public issues containing vulnerability details. Never include real tokens, API keys, or student data in a report.

If the private reporting form is unavailable, do not post vulnerability details publicly. Open a public issue with no technical details and ask maintainers to enable private vulnerability reporting or provide a private reporting route. Do not attach logs, proof-of-concept code, or affected user data to that issue.

Scope: this bot's handling of the model key, long-lived agent token, job-scoped claim tokens, assignment content, network requests, and model output. The iBacalao server must sanitize model-generated HTML before storing or rendering it; self-hosted servers must meet the same requirement.
