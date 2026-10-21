# ibacalao-homework-automation

Open-source local agent that turns your iBacalao assignment queue into **drafts for you to review**. It never submits anything to your school, and it never uses a shared model key. You choose how the writing is done:

| Mode | Use it when | Needs |
|---|---|---|
| **MCP** (`npm run mcp`) | You already pay for an AI subscription (Claude, ChatGPT, etc.) in an app that supports MCP | Your AI app, no API key |
| **API key / local model** (`npm start`) | You have your own API key or run a local model | An OpenAI-compatible endpoint |

Your agent token only goes to the iBacalao server you configure (HTTPS enforced, redirects refused). In API mode your model key only goes to the endpoint you configure. No local CLI is ever executed.

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
      "command": "npx",
      "args": ["tsx", "/absolute/path/to/ibacalao-homework-automation/src/mcp.ts"],
      "env": { "IBACALAO_AGENT_TOKEN": "<your agent token>" }
    }
  }
}
```

Then ask your AI app: "Claim the next homework job, write a draft, and submit it." It uses three tools: `claim_homework_job`, `submit_homework_draft`, `fail_homework_job`. The AI work happens inside your own subscription. Use a chat that has no other powerful tools enabled (files, shell, browser), because assignment text is untrusted input.

## API-key mode

```bash
cp .env.example .env   # fill in, then export the variables
npm run once           # one job
npm start              # keep polling
```

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
