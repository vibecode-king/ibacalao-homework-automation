# ibacalao-ping-bot

A small local agent that turns assignment prompts into **drafts for you to review**. It runs on your computer, calls **your own** model API key (or a local model), and saves the result to your iBacalao account. It never submits anything to your school.

- Your model key stays on your machine. It is only ever sent to the model endpoint you configure.
- Your agent token only goes to the iBacalao server you configure (HTTPS enforced, redirects refused).
- No local CLI execution. The bot only makes HTTP requests.
- Output size, request size and time are bounded.

## Use it

```bash
npm ci
cp .env.example .env   # fill it in, then export the variables in your shell
npm run once           # process at most one job
npm start              # keep polling
```

Use drafts as a starting point for your own work and follow your school's academic integrity rules. You are responsible for what you submit.

## Develop

```bash
npm run check          # typecheck + tests (no network, no real keys)
```

See `SECURITY.md` to report a vulnerability.

## License

Not yet chosen. No license is granted until a `LICENSE` file is added.
