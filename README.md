<p align="center">
  <img src=".github/readme/hero.svg" alt="iBacalao Homework Automation: local pairing and health checks; assignment processing is paused" width="100%">
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#current-integration-status">Current status</a> ·
  <a href="docs/PROTOCOL.md">Protocol</a> ·
  <a href="SECURITY.md">Security</a>
</p>

<p align="center"><strong>Pairing and health checks are available. Assignment processing is paused until DOCX-preserving support is ready.</strong></p>

## Current integration status

> [!IMPORTANT]
> The current iBacalao integration lets you pair the worker and report its heartbeat, but it does not release assignment content. Job claims return `paused: true` with reason `docx_round_trip_not_ready`. The server also rejects the worker's legacy `artifactHtml` completion format. **Do not use this integration to process assignments yet.**

| Available now | Paused |
|---|---|
| Pair the local worker with a one-time Homework setup code. | Claim assignment prompts and send them to a model. |
| Save the agent token to local `.env` with owner-only permissions. | Generate and save student drafts. |
| Report worker health to iBacalao. | Complete a DOCX-preserving edit and save round trip. |

`artifactHtml` is HTML, not a DOCX document. The worker never submits work to a school platform. See the [agent protocol](docs/PROTOCOL.md) for the current endpoint contract.

## This repository

This is the local TypeScript worker and its static UI preview. It contains the pairing command, agent health reporting, an MCP server, and an OpenAI-compatible API runner. The model paths are present, but the current iBacalao integration pauses before any assignment prompt reaches them.

## Quick start

Requires Node.js 20 or newer.

```sh
git clone https://github.com/vibecode-king/ibacalao-homework-automation.git
cd ibacalao-homework-automation
npm ci
```

In iBacalao, open **Homework → Setup** and create a one-time pairing code. It expires after ten minutes and can be used once. Then pair this computer:

```sh
npm run pair
```

Enter the server URL shown in Homework settings, then paste the code. The worker exchanges it directly with iBacalao and saves the server URL and long-lived token in `.env` with owner-only permissions. The token is not printed or sent through the browser. A new pairing rotates the previous token. **Never commit `.env`.**

For a Vercel preview, enter that exact preview URL when `npm run pair` asks for the server URL.

## Choose a model path

The worker supports two ways to connect a model. In the current integration, both can report status but neither receives assignment content while job claiming is paused.

| | MCP host | API or local model |
|---|---|---|
| Start | MCP-capable AI app launches `src/mcp.ts` | `npm run once` or `npm start` |
| Model access | Your MCP app uses its configured AI plan or model | Your OpenAI-compatible endpoint and optional API key |
| Credential in worker | iBacalao agent token | iBacalao agent token and model settings |
| Current assignment flow | Claim returns paused before exposing a prompt | Claim returns paused before calling the model |

<details>
<summary><strong>MCP configuration</strong></summary>

After pairing, copy `IBACALAO_BASE_URL` and `IBACALAO_AGENT_TOKEN` from your local `.env` into your AI app's MCP configuration. Replace both paths with the absolute path to your clone. Protect the config file because it contains the long-lived token.

```json
{
  "mcpServers": {
    "ibacalao-homework": {
      "command": "/absolute/path/to/ibacalao-homework-automation/node_modules/.bin/tsx",
      "args": ["/absolute/path/to/ibacalao-homework-automation/src/mcp.ts"],
      "env": {
        "IBACALAO_BASE_URL": "https://app.ibacalao.com",
        "IBACALAO_AGENT_TOKEN": "<copy from your local .env>"
      }
    }
  }
}
```

The MCP server registers `claim_homework_job`, `submit_homework_draft`, and `fail_homework_job`. Currently, the claim tool returns a paused message before a prompt or job-scoped claim token is provided. The completion tool sends legacy HTML, which the current integration rejects.

</details>

<details>
<summary><strong>API key or local model</strong></summary>

Add your model settings to the `.env` created by pairing. Set `IBACALAO_LLM_API_KEY` to use OpenAI's default endpoint, or set `IBACALAO_LLM_BASE_URL` to use another OpenAI-compatible `/chat/completions` endpoint. A local model server may not need an API key.

| Variable | Purpose |
|---|---|
| `IBACALAO_BASE_URL` | iBacalao server URL, saved by pairing. HTTPS is required except for localhost. |
| `IBACALAO_AGENT_TOKEN` | Long-lived agent token, saved by pairing. Keep it secret. |
| `IBACALAO_LLM_BASE_URL` | OpenAI-compatible model endpoint. |
| `IBACALAO_LLM_API_KEY` | Your key for the configured model endpoint. |
| `IBACALAO_LLM_MODEL` | Model name sent to the endpoint. |
| `IBACALAO_LLM_MAX_TOKENS` | Output cap per draft; defaults to 8,000 and accepts values from 1 to 32,000. |

The scripts read environment variables from the process; they do not load `.env` automatically. In macOS/Linux bash or zsh, load it and start a health/claim cycle:

```sh
set -a
. ./.env
set +a
npm run once   # one cycle; reports that drafting is paused
# or:
npm start      # keep polling and reporting health
```

See [.env.example](.env.example) for the model settings template. On Windows, set the values in your shell or MCP app configuration.

</details>

<details>
<summary><strong>How pairing and claiming work</strong></summary>

```mermaid
flowchart LR
    C[One-time code in Homework settings] --> P[npm run pair]
    P --> X[Worker exchanges code with iBacalao]
    X --> E[Token saved in local .env]
    E --> W[MCP or API worker reports health]
    W --> Q[Claim request]
    Q --> R[Paused response; no assignment content returned]
```

Pairing uses a short-lived code. The browser does not receive the long-lived token; the local worker writes it to `.env` with owner-only permissions. After pairing, both worker modes can report health. The current claim response stops before assignment content or a model request.

</details>

## Project layout

| Path | Purpose |
|---|---|
| `src/pair.ts` | One-time pairing and local token storage |
| `src/ping.ts` | API worker polling and health reporting |
| `src/mcp.ts` | MCP server and homework tools |
| `src/agentRunner.ts` | OpenAI-compatible model request handling |
| `src/client.ts` | iBacalao API client |
| `app-preview.html` | Static UI preview; separate from the live worker connection |
| `docs/PROTOCOL.md` | Pairing, health, and job endpoint contract |

## Privacy and security

- The pairing code is exchanged directly between the local worker and iBacalao. The long-lived token is stored in `.env` with owner-only permissions and must not be committed.
- In API mode, the worker sends assignment prompts and your model key only to the configured model endpoint when the server provides a job. In MCP mode, the MCP host and its model provider may receive the prompt and job-scoped claim token. The current paused response contains neither.
- Non-local server URLs require HTTPS, redirects are refused, and upstream responses are size-limited. Unsandboxed local AI CLI execution is disabled.
- The server must sanitize generated HTML before storing or rendering it. This worker does not sanitize HTML, and the legacy HTML field does not satisfy DOCX round-trip support.
- Treat assignment text as untrusted data. Review your provider's retention settings and send only material you are allowed to share.

For vulnerability reports, follow [SECURITY.md](SECURITY.md).

## Development

```sh
npm run check
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidance. Licensed under the [MIT License](LICENSE).
