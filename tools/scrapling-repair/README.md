# Scrapling parser repair helper

Parser-only adaptive DOM recipe repair. It accepts HTML already loaded by the
student's browser and never makes network requests. Development can run the
Python source directly; packaged macOS builds compile it into a self-contained
`WatcherRuntime/scrapling-repair` executable so the student's Mac does not need
Python or Scrapling installed.

## Guardrails

- Install plain `scrapling` only. Do **not** install `scrapling[fetchers]`.
- Do not import `scrapling.fetchers`, `scrapling.spiders`, stealth classes,
  proxy helpers, CAPTCHA/challenge solvers, or browser automation here.
- stdin is capped at 2 MiB; HTML at 1.5 MiB; stdout at 1 MiB.
- The Node parent hard-kills the helper after a 12-second cold-start budget (15-second absolute cap).
- A repair is only a candidate. `lib/school/validation.ts` must approve it
  before a local recipe can become active.

## Contract

Input is one JSON object on stdin with `oldRecipe`, a Scrapling-compatible
`oldSignature`, `currentHtml`, `currentUrl`, and `expectedEntity`.

The sidecar also supports a `signature` operation used during local learning to
turn one sanitized academic-card element into the JSON signature persisted by
the recipe store. The sanitized HTML itself is not persisted.

The signature is the JSON form of the unique element properties previously
captured by Scrapling's adaptive storage (`save` + `retrieve`). The R&D fixture
builder should create it from a known-good historical DOM; production school
HTML must not be persisted merely to make this experiment work.

Output is one JSON object on stdout matching `AdaptiveDomRepairResult`.

The release packager pins plain `scrapling` and PyInstaller versions, builds an
arm64 helper, smoke-tests it, and signs the nested executable before sealing the
outer app. No Scrapling fetcher extras are installed.

Scrapling exposes relocation through an integer percentage threshold rather
than returning the winning score directly. The sidecar binary-searches that
public threshold to estimate the top similarity score, then returns a single
candidate only. Ties are reported as `ambiguous` and must escalate instead of
silently changing academic data.
