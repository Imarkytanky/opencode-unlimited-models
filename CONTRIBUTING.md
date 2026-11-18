# Contributing

## Development setup

```bash
git clone <your-fork>
cd opencode-unlimited-models-final
bun install
bash test-e2e.sh --quick
```

## Project structure

See [README.md](./README.md) for the full directory layout and architecture diagram.

## Making changes

1. **Code changes**: edit files, then run `bash test-e2e.sh --quick` to verify
2. **Plugin changes** (`plugins/reconcile.ts`): run `cd plugins && bun test reconcile.test.ts`
3. **Contract test changes** (`verify-a-contract/`): run `bash verify-a-contract/verify-a-contract.sh --selftest`
4. **Shell scripts**: run `bash -n <script.sh>` for syntax check

## Testing

| Test | Command | What it validates |
|---|---|---|
| Quick E2E (~15s) | `bash test-e2e.sh --quick` | 6 layers (skips CF + G) |
| Full E2E (~60s) | `bash test-e2e.sh` | All 8 layers |
| Contract (mock) | `bun run test:contract` | 9/9 assertions C1-C9 |
| Contract (real) | `bun run test:contract-real` | 9/9 against live opencode Console |
| Plugin unit tests | `bun run test:plugin` | 7/7 reconcile tests |
| Selftest | `bun run test:selftest` | Assertion engine validates PASS/FAIL fixtures |
| Smoke | `bun run test:smoke` | Mock gateway boots, auth enforced |

## Release process

1. Update `CHANGELOG.md` with the new version
2. Bump `package.json` version
3. Clean runtime artifacts: `rm -rf node_modules .env.local */node_modules`
4. Build tarball: `tar -czf vX.Y.Z.tar.gz opencode-unlimited-models-final`
5. Compute sha256: `sha256sum vX.Y.Z.tar.gz > vX.Y.Z.tar.gz.sha256`
6. Extract to `/tmp` and run `bash test-e2e.sh --quick` from the clean extraction

## Code style

- Shell: `set -Eeuo pipefail`, use `log()`/`ok()`/`bad()`/`warn()` helpers
- TypeScript: strict mode, `@opencode/plugin` types
- Python: type hints, `from __future__ import annotations`
- No hardcoded user paths — use `$HOME` or `$(dirname "${BASH_SOURCE[0]}")`
- No secrets in committed files — use `.env.local` (gitignored) + `{env:VAR}` in config
