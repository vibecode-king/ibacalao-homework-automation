# iBacalao Homework Automation

Open-source local agent that turns your iBacalao assignment queue into **drafts for you to review**. It never submits anything to your school, and it never uses a shared model key. You choose how the writing is done:

| Mode | Use it when | Needs |
|---|---|---|
| **MCP** (`npm run mcp`) | You already pay for an AI subscription (Claude, ChatGPT, etc.) in an app that supports MCP | Your AI app, no API key |
| **API key / local model** (`npm start`) | You have your own API key or run a local model | An OpenAI-compatible endpoint |

Your long-lived agent token only goes to the iBacalao server you configure (HTTPS enforced, redirects refused). In API mode your model key and assignment prompt only go to the endpoint selected by `IBACALAO_LLM_BASE_URL`; if you leave it blank and set only an OpenAI API key, the endpoint defaults to OpenAI. No local AI CLI is executed.

## Data and privacy

This agent runs on your computer, but assignment content is sent to the AI service you choose. In API mode, the full job prompt returned by iBacalao is sent to `IBACALAO_LLM_BASE_URL`. In MCP mode, the MCP tool returns the prompt and a job-scoped `claimToken` to the AI app hosting this server so it can save the draft. The host app may send both to its model provider and retain them under that provider's settings. The long-lived `IBACALAO_AGENT_TOKEN` stays in the MCP server process and is used to call the iBacalao API; the MCP app configuration contains that token, so protect that configuration file. A prompt can include assignment text and source material from a school platform. Check the provider's retention and training settings and make sure you are allowed to send the material before using the agent.

The agent sends model-generated `artifactHtml` to the iBacalao completion API. The API protocol requires the server to sanitize that HTML before storing or rendering it. A self-hosted server must provide the same protection; this local agent does not sanitize HTML itself. See [the protocol](docs/PROTOCOL.md).

## Setup (both modes)

```bash
npm ci
```

In iBacalao, open Settings > Homework agent and create an agent token (shown once). Never commit it.

## MCP mode (use your AI subscription)

Add this server to your MCP-capable AI app (example config):

```json
{
  "mcpServers": {
    "ibacalao-homework": {
      "command": "/absolute/path/to/ibacalao-homework-automation/node_modules/.bin/tsx",
      "args": ["/absolute/path/to/ibacalao-homework-automation/src/mcp.ts"],
      "env": { "IBACALAO_AGENT_TOKEN": "<your agent token>" }
    }
  }
}
```

Replace both paths with the absolute path in your clone. Run `npm ci` there first so the local `tsx` executable exists.

Then ask your AI app: "Claim the next homework job, write a draft, and submit it." It uses three tools: `claim_homework_job`, `submit_homework_draft`, `fail_homework_job`. The AI work happens inside your own subscription. Use a chat that has no other powerful tools enabled (files, shell, browser), because assignment text is untrusted input.

## API-key mode

```bash
cp .env.example .env   # edit with your values
set -a                 # macOS/Linux bash or zsh: export values from .env
. ./.env
set +a
npm run once           # one job
npm start              # keep polling
```

The scripts read environment variables from the process; they do not load `.env` themselves. On Windows, set the variables in your shell or MCP app configuration instead.

`IBACALAO_LLM_MAX_TOKENS` caps output per draft so a bad job cannot run up your bill.

## Self-hosting a different server

The bot speaks a small HTTP protocol, documented in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Responsible use

Drafts are a starting point for your own work. Follow your school's academic integrity rules. You are responsible for what you submit.

## Develop

```bash
npm run check   # typecheck + tests, no network, no real keys
```

See [SECURITY.md](SECURITY.md) to report a vulnerability. Licensed under the MIT License.
