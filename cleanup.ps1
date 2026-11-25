# Spotify display repo cleanup. Run from PowerShell:
#   cd $HOME\Desktop\spotify-display1 ; .\cleanup.ps1
$ErrorActionPreference = "Stop"
git status --short
git branch --show-current

# 1. Stop tracking anything that's now ignored (files stay on disk)
git rm -r --cached --quiet --ignore-unmatch build-ipa .codex .claude/settings.local.json .claude/worktrees .impeccable/config.local.json .cursor/plans .cursor/hooks.json
git rm -r --cached --quiet --ignore-unmatch "*.ipa"

# 2. Delete the downloaded unsigned IPA (re-downloadable from Actions)
if (Test-Path build-ipa) { Remove-Item -Recurse -Force build-ipa }

# 3. Remove stale agent worktrees inside .claude
git worktree prune
git worktree list

# 4. Add skills/agents + everything else, commit, push
git add .gitignore .claude/skills .claude/agents .cursor/skills .cursor/agents .agents .github skills-lock.json
git add -A
git status --short
git commit -m "Repo cleanup: ignore local artifacts, track skills/agents, drop downloaded IPA"
git push
Write-Host "Done. Check that worktrees -audit and -themes are merged before removing them (see HANDOFF)."
