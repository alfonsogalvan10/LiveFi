#!/usr/bin/env bash
# ============================================================
# LiveFi — run the exact checks CI runs, locally, before pushing.
#
#   ./scripts/ci.sh                  # everything
#   SKIP_FRONTEND=1 ./scripts/ci.sh  # skip the slow frontend build
#   SKIP_PYTHON=1 ./scripts/ci.sh
#   SKIP_COMPOSE=1 ./scripts/ci.sh
#
# Written for bash 3.2 (the version macOS ships). Avoids `${arr[@]}` on
# empty arrays, `mapfile`, and associative arrays, all of which break there.
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILED=""
PASS_COUNT=0

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$1"; }
pass() { printf "    \033[32m✓\033[0m %s\n" "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf "    \033[31m✗\033[0m %s\n" "$1"; FAILED="$FAILED\n      - $1"; }

# Prefer a real 3.11+ interpreter; the service code uses modern syntax.
PYTHON=""
for candidate in python3.13 python3.12 python3.11 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
      PYTHON="$candidate"; break
    fi
  fi
done

# ------------------------------------------------------------
# Python services
# ------------------------------------------------------------
if [ "${SKIP_PYTHON:-0}" != "1" ]; then
  if [ -z "$PYTHON" ]; then
    step "Python services"
    fail "no Python >= 3.11 found (try: brew install python@3.12)"
  else
    for service in ingestion-api query-api; do
      step "Python: $service  (interpreter: $PYTHON)"
      VENV=".venv-ci/$service"

      if [ ! -x "$VENV/bin/pytest" ]; then
        echo "    first run — creating venv and installing dependencies..."
        if ! "$PYTHON" -m venv "$VENV" >/dev/null 2>&1; then
          fail "$service: venv creation"; continue
        fi
        "$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1
        if ! "$VENV/bin/pip" install -q -r "services/$service/requirements.txt" >/dev/null 2>&1; then
          fail "$service: dependency install"; continue
        fi
      fi

      if ( cd "services/$service" && "../../$VENV/bin/ruff" check . ); then
        pass "$service: ruff"
      else
        fail "$service: ruff"
      fi

      if ( cd "services/$service" && "../../$VENV/bin/python" -m pytest -q ); then
        pass "$service: pytest"
      else
        fail "$service: pytest"
      fi
    done
  fi
fi

# ------------------------------------------------------------
# Frontend
# ------------------------------------------------------------
if [ "${SKIP_FRONTEND:-0}" != "1" ]; then
  step "Frontend"
  if ! command -v pnpm >/dev/null 2>&1; then
    fail "pnpm not found (try: brew install pnpm)"
  else
    if ( cd frontend && pnpm install --frozen-lockfile >/dev/null 2>&1 ); then
      pass "install --frozen-lockfile"
    else
      fail "install --frozen-lockfile (lockfile out of sync? run 'pnpm install' and commit)"
    fi

    if ( cd frontend && pnpm lint ); then
      pass "lint"
    else
      fail "lint"
    fi

    if ( cd frontend && pnpm typecheck ); then
      pass "typecheck"
    else
      fail "typecheck"
    fi

    if [ "${SKIP_BUILD:-0}" = "1" ]; then
      echo "    (skipping build — SKIP_BUILD=1)"
    elif ( cd frontend && pnpm build >/dev/null 2>&1 ); then
      pass "build"
    else
      fail "build"
    fi
  fi
fi

# ------------------------------------------------------------
# Docker Compose validation
# ------------------------------------------------------------
if [ "${SKIP_COMPOSE:-0}" != "1" ]; then
  step "Docker Compose validation"
  [ -f .env ] || cp .env.example .env

  # `config -q` parses and resolves the file without contacting the daemon.
  if docker compose -f docker-compose.yml config -q 2>/dev/null; then
    pass "core compose"
  else
    fail "core compose"
  fi

  if docker compose -f docker-compose.yml -f docker-compose.observability.yml config -q 2>/dev/null; then
    pass "observability compose"
  else
    fail "observability compose"
  fi

  for profile in stage1 stage2 stage3 stage4; do
    if docker compose --profile "$profile" config -q 2>/dev/null; then
      pass "profile: $profile"
    else
      fail "profile: $profile"
    fi
  done
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
step "Summary"
if [ -z "$FAILED" ]; then
  printf "    \033[32mAll %d checks passed.\033[0m Safe to push.\n" "$PASS_COUNT"
  exit 0
fi
printf "    \033[31mSome checks failed (%d passed):\033[0m%b\n" "$PASS_COUNT" "$FAILED"
echo
echo "    Fix the failures above, then re-run: make ci"
exit 1
