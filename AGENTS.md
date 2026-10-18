# AGENTS.md — rules for LLMs working in LiveFi

Applies to every agent and model, always. Keep it in mind before touching any file.

## Communication

- **Be short.** Bullet points, no filler, no restating the question.
- **Explain *why*, briefly.** The user is new to distributed systems — define a term on first use, one line max.
- **Ask before acting.** Never run a command, git operation, install, or destructive action until the reason and scope are agreed. Propose it, wait for a yes.
- **Never claim something works.** Verify, or say it is a stub. See "Known gaps" in `.pi/skills/livefi-platform/SKILL.md`.

## Code

- **Simplest thing that works.** No speculative abstraction, no unused config, no dependency unless required.
- **Document everything, precisely and concisely.** Every module, class, and non-obvious function gets a docstring/comment stating what it does and why. Inline-comment tricky logic only — do not narrate the obvious.
- **Typed and explicit.** Python: type hints + Pydantic contracts. TS: no `any`. Config via a typed `Settings` class from env vars, never hardcoded.
- **Match existing structure.** FastAPI services follow `app/{main,api,core,db,schemas}` + `tests/`, `Dockerfile`, `requirements.txt`.
- **Respect the design rules** in `.pi/skills/livefi-platform/SKILL.md` (no direct Kafka publish, Kong-only entrypoint, idempotent writes, Postgres writes / ClickHouse reads). Flag any request that would break one.

## Docs

- **Any change updates the docs** — briefly. One or two lines in the right place, not an essay.
  - Behaviour/design decision → `docs/architecture.md`
  - Tier explanation → `docs/tiers-explained.md`
  - Ports, commands, setup → `README.md`
- Keep docs in sync in the same change as the code. Stale docs are a bug.

## Verify

- Run `make ci` before declaring work done; it mirrors GitHub Actions.
- Add or update tests for any behaviour change.
- Never commit `.env`, secrets, or generated artifacts.

## Scope

- Change only what the task requires. No drive-by refactors.
- If a fix needs a design decision, stop and ask first.
