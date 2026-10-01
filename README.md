# linespec-setup

One-shot setup for [LineSpec](https://github.com/livecodelife/linespec) on macOS, Linux and **Windows via WSL**.

## Windows

1. Install WSL (PowerShell as admin): `wsl --install -d Ubuntu`, then open the Ubuntu terminal.
2. Install Docker Desktop and enable **Settings → Resources → WSL integration** for Ubuntu (only needed for `linespec test`).
3. Run the script **inside WSL**, from your repo (keep repos under `~/`, not `/mnt/c`, for speed):

```bash
cd ~/code/my-service
curl -fsSL https://raw.githubusercontent.com/ccowen-linq/linespec-setup/main/setup.sh | bash -s -- --yes
```

## What it does

| Step | Detail |
|------|--------|
| LineSpec binary | existing install → Homebrew → checksum-verified GitHub release (`~/.local/bin`) → `go install` |
| Ollama + `nomic-embed-text` | installs Ollama, starts `ollama serve` if there is no systemd (common on WSL), pulls the model, verifies `/v1/embeddings` |
| Repo setup | in the current git repo (or `--repo PATH`): `linespec provenance install-skills`, `install-plugin`, `install-hooks` |
| Docker check | warns, with WSL-specific guidance, if Docker isn't reachable |

Re-running is safe; satisfied steps are skipped and a summary is printed. Exit code is non-zero if a step failed.

## Options

```
--repo PATH      repo to set up (default: current dir if a git repo)
--version X.Y.Z  pin a LineSpec version (default: latest)
--skip-ollama    skip Ollama and the embedding model
--yes            allow sudo steps (Ollama installer, apt packages)
--dry-run        show the plan, change nothing
```

Env overrides: `LINESPEC_REPO`, `EMBED_MODEL`, `OLLAMA_HOST_URL`, `INSTALL_DIR`.

Without `--yes` the script never runs sudo; it prints the command for you to run.

## Using Ollama for `provenance search`

The script does not edit your repo's `.linespec.yml`. It prints this snippet at the end, to paste under `provenance.embedding`:

```yaml
embedding:
  provider: openai
  base_url: http://localhost:11434/v1
  api_key: ollama
  index_model: nomic-embed-text
  query_model: nomic-embed-text
```

Embeddings from different models have different widths. If the repo commits an index built with Voyage, rebuild it locally with `linespec provenance index` rather than committing the result.

On WSL without systemd, restart Ollama after a reboot with `nohup ollama serve &` (or re-run this script).
