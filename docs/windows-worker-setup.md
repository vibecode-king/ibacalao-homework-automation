# Windows Homework worker

The native SwiftUI desktop app in this repository is macOS-only. On Windows, use the Homework page in Edge or Chrome and run the TypeScript worker in the background. The worker only claims assignments selected in Homework, and the server blocks claims without required AI consent. It saves drafts for review and never submits to school.

## Install

1. Install Node.js 20.12 or newer.
2. Clone this repository, open PowerShell in the repository, and run `npm ci`.
3. In Homework, create a one-time worker connection code. Then run `npm run pair` in PowerShell and follow the prompts. Pairing writes the worker token to the local `.env` file and restricts that file to your Windows account.
4. Add `IBACALAO_LLM_BASE_URL` for an OpenAI-compatible model endpoint, or `IBACALAO_LLM_API_KEY` to use the default OpenAI endpoint. Set `IBACALAO_LLM_MODEL` unless the selected Homework job provides a model name.
5. Run `npm run worker:windows:setup`. This creates a per-user Scheduled Task that starts the worker when you sign in. It does not require administrator rights.

The setup command checks the Node version, pairing token, model endpoint, and worker dependencies. It restricts the `.env` file ACL to your Windows account and SYSTEM. Credentials are not copied into the scheduled task or its command line.

## Check or stop

Check the task:

```powershell
Get-ScheduledTask -TaskName 'iBacalao Homework Agent' | Select-Object TaskName, State
```

Read its log:

```powershell
Get-Content "$env:LOCALAPPDATA\iBacalao\HomeworkAgent\worker.log" -Tail 40
```

The log must say it is connected. If it reports HTTP 401, create a fresh code in Homework, run `npm run pair`, then restart the task. A `ready_for_review` line means the draft was saved; it does not mean the school was changed.

To stop the background worker, use Task Scheduler to stop **iBacalao Homework Agent**. This leaves the paired `.env` and local attempt counters in place.

## Support boundary

This installs the worker, not a native Windows desktop app. Sign-in, assignment selection, consent, and draft review happen in the Homework website. The Windows worker has not yet been exercised on a Windows machine; verify the setup and first draft on Windows before advertising native Windows app support.
