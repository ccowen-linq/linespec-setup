#!/usr/bin/env bash
# linespec-setup — one-shot onboarding for LineSpec on macOS, Linux and WSL.
#
#   curl -fsSL https://raw.githubusercontent.com/ccowen-linq/linespec-setup/main/setup.sh | bash
#   curl -fsSL .../setup.sh | bash -s -- --repo ~/code/my-service --yes
#
# Installs: linespec binary, Ollama + an embedding model (for `provenance search`
# without a Voyage key), and — inside a git repo — the Claude Code skills,
# provenance plugin and git hooks. Safe to re-run; satisfied steps are skipped.

set -euo pipefail

LINESPEC_REPO="${LINESPEC_REPO:-livecodelife/linespec}"
LINESPEC_VERSION="${LINESPEC_VERSION:-latest}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
OLLAMA_HOST_URL="${OLLAMA_HOST_URL:-http://localhost:11434}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

DRY_RUN=0
YES=0
SKIP_OLLAMA=0
REPO_DIR=""
FAILED=()
SUMMARY=()

usage() {
  cat <<USAGE
Usage: setup.sh [options]
  --repo PATH      Git repo to set up (skills, plugin, hooks). Default: current dir if it is a git repo.
  --version X.Y.Z  LineSpec version to install (default: latest release)
  --skip-ollama    Don't install Ollama / the embedding model
  --yes            Allow steps that need sudo (Ollama installer, apt packages)
  --dry-run        Print what would happen, change nothing
  -h, --help       Show this help
USAGE
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
ok()   { SUMMARY+=("ok      $1"); }
skip() { SUMMARY+=("skipped $1"); }
fail() { SUMMARY+=("FAILED  $1"); FAILED+=("$1"); }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

is_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }

detect_platform() {
  case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=darwin ;;
    *) echo "Unsupported OS: $(uname -s). On Windows, run this inside WSL." >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

# Run a command that needs root: directly if root, via sudo only with --yes.
as_root() {
  if [ "$(id -u)" = 0 ]; then run "$@"
  elif [ "$YES" = 1 ] && have sudo; then run sudo "$@"
  else
    warn "needs root; re-run with --yes, or run yourself:  sudo $*"
    return 1
  fi
}

preflight() {
  if ! have curl; then
    as_root apt-get install -y curl || { echo "curl is required" >&2; exit 1; }
  fi
  have git || warn "git not found — repo setup and hooks will be skipped"
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) warn "$INSTALL_DIR is not on PATH; add to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\"" ;;
  esac
  export PATH="$INSTALL_DIR:$PATH"
}

# ---------- linespec binary ----------

latest_version() {
  curl -fsSL "https://api.github.com/repos/$LINESPEC_REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1
}

sha_check() {
  if have sha256sum; then sha256sum -c -; else shasum -a 256 -c -; fi
}

install_from_release() {
  local ver="$1" name base tmp
  name="linespec_${ver}_${OS}_${ARCH}.tar.gz"
  base="https://github.com/$LINESPEC_REPO/releases/download/v${ver}"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] download $base/$name → $INSTALL_DIR/linespec"; return 0
  fi
  tmp="$(mktemp -d)"
  log "Downloading $name"
  curl -fsSL -o "$tmp/$name" "$base/$name" || { rm -rf "$tmp"; return 1; }
  if curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt" 2>/dev/null; then
    if ! ( cd "$tmp" && grep " $name\$" checksums.txt | sha_check >/dev/null 2>&1 ); then
      warn "checksum verification failed for $name"; rm -rf "$tmp"; return 1
    fi
  else
    warn "no checksums.txt for v$ver; skipping verification"
  fi
  mkdir -p "$INSTALL_DIR"
  tar -xzf "$tmp/$name" -C "$tmp" linespec
  install -m 0755 "$tmp/linespec" "$INSTALL_DIR/linespec"
  rm -rf "$tmp"
}

install_linespec() {
  log "LineSpec binary"
  local want="$LINESPEC_VERSION"
  if have linespec && [ "$want" = latest ]; then
    skip "linespec (already installed: $(linespec --version 2>/dev/null | head -1 || echo present))"; return
  fi
  if [ "$want" = latest ]; then
    if have brew && [ "$DRY_RUN" = 0 ] && brew tap livecodelife/linespec >/dev/null 2>&1 && brew install linespec; then
      ok "linespec (brew)"; return
    fi
    want="$(latest_version || true)"
    [ -n "$want" ] || warn "could not resolve latest release"
  fi
  if [ -n "$want" ] && install_from_release "$want"; then
    ok "linespec $want → $INSTALL_DIR"; return
  fi
  if have go; then
    log "Falling back to go install"
    if run go install "github.com/livecodelife/linespec/v3/cmd/linespec@${want:+v$want}${want:-latest}"; then
      ok "linespec (go install)"; return
    fi
  fi
  fail "linespec binary"
}

# ---------- Ollama ----------

ollama_up() { curl -fsS "$OLLAMA_HOST_URL/api/tags" >/dev/null 2>&1; }

install_ollama() {
  if [ "$SKIP_OLLAMA" = 1 ]; then skip "ollama (--skip-ollama)"; return; fi
  log "Ollama + $EMBED_MODEL"
  if ! have ollama; then
    if [ "$OS" = darwin ] && have brew; then
      run brew install ollama || { fail "ollama install"; return; }
    else
      if [ "$(id -u)" != 0 ] && [ "$YES" != 1 ]; then
        warn "Ollama's installer needs sudo. Re-run with --yes, or run:  curl -fsSL https://ollama.com/install.sh | sh"
        fail "ollama install (needs --yes)"; return
      fi
      have zstd || as_root apt-get install -y zstd || true
      run bash -c 'curl -fsSL https://ollama.com/install.sh | sh' || { fail "ollama install"; return; }
    fi
    ok "ollama installed"
  else
    skip "ollama (already installed)"
  fi

  if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] ensure ollama is serving; pull $EMBED_MODEL"; return; fi

  if ! ollama_up; then
    # WSL often has no systemd, so the service never starts on its own.
    if [ "$OS" = linux ] && have systemctl && systemctl is-system-running >/dev/null 2>&1; then
      as_root systemctl start ollama || true
    fi
    if ! ollama_up; then
      log "Starting 'ollama serve' in the background"
      mkdir -p "$HOME/.local/state"
      nohup ollama serve >"$HOME/.local/state/ollama.log" 2>&1 &
    fi
    for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
  fi
  if ! ollama_up; then fail "ollama server (see ~/.local/state/ollama.log)"; return; fi

  if curl -fsS "$OLLAMA_HOST_URL/api/tags" | grep -q "\"$EMBED_MODEL"; then
    skip "model $EMBED_MODEL (already pulled)"
  elif ollama pull "$EMBED_MODEL"; then
    ok "model $EMBED_MODEL pulled"
  else
    fail "model pull $EMBED_MODEL"; return
  fi

  # End-to-end check through the OpenAI-compatible endpoint LineSpec will use.
  if curl -fsS "$OLLAMA_HOST_URL/v1/embeddings" -H 'Content-Type: application/json' \
       -d "{\"model\":\"$EMBED_MODEL\",\"input\":\"ping\"}" | grep -q '"embedding"'; then
    ok "embeddings endpoint verified ($OLLAMA_HOST_URL/v1/embeddings)"
  else
    fail "embeddings endpoint check"
  fi
}

# ---------- repo setup ----------

setup_repo() {
  if [ -z "$REPO_DIR" ] && have git && git rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_DIR="$(git rev-parse --show-toplevel)"
  fi
  if [ -z "$REPO_DIR" ]; then
    skip "repo setup (no --repo and not inside a git repo)"; return
  fi
  log "Repo setup: $REPO_DIR"
  if [ ! -d "$REPO_DIR/.git" ]; then fail "repo setup ($REPO_DIR is not a git repo root)"; return; fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] (cd $REPO_DIR && linespec provenance install-skills | install-plugin | install-hooks)"; return
  fi
  if ! have linespec; then fail "repo setup (linespec not on PATH)"; return; fi
  local sub
  for sub in install-skills install-plugin install-hooks; do
    if ( cd "$REPO_DIR" && linespec provenance "$sub" ); then ok "linespec provenance $sub"
    else fail "linespec provenance $sub"; fi
  done
}

# ---------- docker (informational) ----------

check_docker() {
  if have docker && docker info >/dev/null 2>&1; then skip "docker (reachable)"; return; fi
  if is_wsl; then
    warn "Docker not reachable. For 'linespec test': install Docker Desktop on Windows and enable Settings > Resources > WSL integration for this distro."
  else
    warn "Docker not reachable; 'linespec test' needs it (provenance commands do not)."
  fi
}

embedding_help() {
  cat <<HELP

Local embeddings: add this under provenance.embedding in your repo's .linespec.yml
(in place of the voyage block):

  embedding:
    provider: openai
    base_url: $OLLAMA_HOST_URL/v1
    api_key: ollama            # any non-empty value; Ollama ignores it
    index_model: $EMBED_MODEL
    query_model: $EMBED_MODEL

Note: vectors from different models have different widths. If your repo commits
.linespec/embeddings.bin built with Voyage, rebuild it locally with
'linespec provenance index' (and don't commit the result) before searching.
HELP
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)        REPO_DIR="${2:?--repo needs a path}"; shift 2 ;;
      --version)     LINESPEC_VERSION="${2#v}"; shift 2 ;;
      --skip-ollama) SKIP_OLLAMA=1; shift ;;
      --yes|-y)      YES=1; shift ;;
      --dry-run)     DRY_RUN=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  detect_platform
  if is_wsl; then log "Detected WSL"; fi
  if [ "$DRY_RUN" = 1 ]; then log "Dry run — nothing will be changed"; fi
  preflight
  install_linespec
  install_ollama
  setup_repo
  check_docker

  echo; log "Summary"
  printf '  %s\n' "${SUMMARY[@]}"
  if [ "$SKIP_OLLAMA" != 1 ]; then embedding_help; fi
  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo; echo "Setup incomplete: ${#FAILED[@]} step(s) failed." >&2; exit 1
  fi
  echo; log "Done."
}

main "$@"
