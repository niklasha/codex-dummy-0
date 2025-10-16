# Repository Guidance

This repository is primarily used to experiment with tooling for the nested `ape` project.
When working anywhere inside the `ape/` directory (or its descendants) use the helper
workflow documented below to manage its child submodules safely.

Key points for contributors:

- Prefer the helper script at `tools/ape_submodule_workflow.sh` for multi-repo workflows.
- Run commands from the repository root and pass `--repo-root ape` (or run the script from
  inside `ape/` and point it at the current directory with `--repo-root .`).
- A typical loop is:
  1. `sh tools/ape_submodule_workflow.sh --repo-root ape status`
  2. `sh tools/ape_submodule_workflow.sh --repo-root ape branch --name feature/<ticket>`
  3. work/commit inside the child repo(s)
  4. `sh tools/ape_submodule_workflow.sh --repo-root ape push --set-upstream`
  5. `sh tools/ape_submodule_workflow.sh --repo-root ape mr --target main`
  6. `sh tools/ape_submodule_workflow.sh --repo-root ape update-parent`
- Do not commit anything inside `ape/**/.git/` or other git metadata directories.
- Keep newly added scripts executable when appropriate (use `chmod +x`).
- REMEMBER to always push and create MRs/PRs to the actual submodule, or the work will get lost, since codex cloud does not include it into its own process!
