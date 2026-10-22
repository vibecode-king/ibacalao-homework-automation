# iBacalao Homework Automation

Local agent that turns your iBacalao assignment queue into **drafts for you to review**. It never submits anything to your school, and it never uses a shared model key. You choose how the writing is done:

| Mode | Use it when | Needs |
|---|---|---|
| **MCP** (`npm run mcp`) | You already pay for an AI subscription (Claude, ChatGPT, etc.) in an app that supports MCP | Your AI app, no API key |
| **API key / local model** (`npm start`) | You have your own API key or run a local model | An OpenAI-compatible endpoint |

Your long-lived agent token only goes to the iBacalao server you configure (HTTPS enforced, redirects refused). In API mode your model key and assignment prompt only go to the endpoint selected by `IBACALAO_LLM_BASE_URL`; if you leave it blank and set only an OpenAI API key, the endpoint defaults to OpenAI. No local AI CLI is executed.

## Data and privacy

This agent runs on your computer, but assignment content is sent to the AI service you choose. In API mode, the full job prompt returned by iBacalao is sent to `IBACALAO_LLM_BASE_URL`. In MCP mode, the MCP tool returns the prompt and a job-scoped `claimToken` to the AI app hosting this server so it can save the draft. The host app may send both to its model provider and retain them under that provider's settings. The long-lived `IBACALAO_AGENT_TOKEN` stays in the MCP server process and is used to call the iBacalao API; the MCP app configuration contains that token, so protect that configuration file. A prompt can include assignment text and source material from a school platform. Check the provider's retention and training settings and make sure you are allowed to send the material before using the agent.

The agent sends model-generated `artifactHtml` to the iBacalao completion API. The API protocol requires the server to sanitize that HTML before storing or rendering it. A self-hosted server must provide the same protection; this local agent does not sanitize HTML itself. See [the protocol](docs/PROTOCOL.md).

The current iBacalao Homework integration pairs the worker and can show its heartbeat, but returns a paused claim response and rejects HTML completion until DOCX-preserving generation and editing are implemented. Do not use this worker to process assignments against that integration yet. The legacy `artifactHtml` field is not a DOCX file.

## Setup (both modes)

```bash
npm ci
```

In iBacalao, open Homework → Setup and create a one-time pairing code. It expires after ten minutes and can be used once. It is not the long-lived agent token. Pairing can be completed while assignment processing is paused.

On the computer that will run the worker, run:

```bash
npm run pair
```

Enter the same iBacalao server URL shown in Homework settings and paste the pairing code. The worker exchanges it directly with iBacalao and saves the long-lived token and server URL to `.env` with owner-only permissions. The browser never receives the agent token. Reload `.env` in your shell before starting the worker, and never commit `.env`.

## MCP mode (use your AI subscription)

Pair the worker on this computer first. Then add this server to your MCP-capable AI app (example config), copying the token from the local `.env` file into the MCP environment:

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

Replace both paths with the absolute path in your clone. Copy both `IBACALAO_BASE_URL` and `IBACALAO_AGENT_TOKEN` from the local `.env` created by `npm run pair`; this keeps preview pairings pointed at the same preview app. Run `npm ci` there first so the local `tsx` executable exists.

When DOCX-preserving processing is enabled by the server, ask your AI app to claim the next homework job, write a draft, and save it for review. It uses three tools: `claim_homework_job`, `submit_homework_draft`, `fail_homework_job`. The current iBacalao integration returns a clear paused response before exposing any assignment content. The AI work happens inside your own subscription. Use a chat that has no other powerful tools enabled (files, shell, browser), because assignment text is untrusted input.

## API-key mode

```bash
cp .env.example .env   # edit with your values
npm run pair           # enter the app's one-time pairing code
set -a                 # macOS/Linux bash or zsh: export values from .env
. ./.env
set +a
npm run once           # one job
npm start              # keep polling
```

The scripts read environment variables from the process; they do not load `.env` themselves. On Windows, set the variables in your shell or MCP app configuration instead.

For a Vercel preview, enter that exact preview deployment URL when `npm run pair` asks for the server URL. The command saves it so later worker requests use the same app.

`IBACALAO_LLM_MAX_TOKENS` caps output per draft so a bad job cannot run up your bill.

For the local Ping Bot, an optional model name in iBacalao's Homework settings overrides `IBACALAO_LLM_MODEL` for that job. Student writing instructions are included in the prompt by iBacalao. The model endpoint address and API key stay in the Ping Bot's local environment; leaving the model setting blank uses the local model value (or `gpt-4o-mini`).

The API worker prints its current state without logging assignment titles. For example:

```text
[homework-agent] Starting API mode (continuous polling every 15 seconds).
[homework-agent] Connected to https://app.ibacalao.com; no assignments are waiting. Checking again in 15 seconds.
[homework-agent] Claimed job job-123; generating draft.
[homework-agent] Draft saved for review. Saved job job-123 as ready_for_review. The school platform was not changed.
```

If generation fails, the worker reports whether it confirmed releasing the job. If it cannot confirm, check the assignment in iBacalao before retrying.

## Self-hosting a different server

The bot speaks a small HTTP protocol, documented in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Responsible use

Drafts are a starting point for your own work. Follow your school's academic integrity rules. You are responsible for what you submit.

## Develop

```bash
npm run check   # typecheck + tests, no network, no real keys
```

See [SECURITY.md](SECURITY.md) to report a vulnerability. Licensed under the MIT License.
