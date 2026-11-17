# git-worktreeinclude

Automatically populate newly created Git worktrees with untracked and ignored files (`.env*`, local configs, `node_modules/`, `.venv/`, build caches) defined in `.worktreeinclude` — using **100% `.gitignore` syntax** and fast **Copy-on-Write (`CoW`)** cloning.

Zero runtime dependencies: implemented as a single self-contained POSIX `sh` script powered directly by Git's native plumbing, working across **Linux**, **macOS**, and **Windows** (`Git Bash`, `PowerShell`, `cmd.exe`, GUI Git clients, and IDE agents).

---

## Features

- **1-Command Install & Uninstall**: Global by default (works across all repos automatically; silent no-op in repos without `.worktreeinclude`), or per-repository with `--local`.
- **Exact `.gitignore` Semantics**: Supports `#` comments, blank lines, `!` negations, `/` root & relative anchors, `*` / `?` / `[...]` globs, `**` recursive globs, trailing `/` directory rules, and `\` escapes.
- **Hierarchical Monorepo Support**: Reads `<primary-worktree>/.worktreeinclude` plus nested `<subdir>/.worktreeinclude` files (whether `.worktreeinclude` itself is tracked, untracked, or Git-ignored), while skipping ignored vendor trees like `node_modules/`.
- **Strict Safety Guarantees**:
  - **Never touches tracked files** in either the primary or target worktree.
  - **Never overwrites** existing files, symlinks, or directories.
  - **Never deletes** any files or directories.
  - **Never blocks `git worktree add`** (warns and exits `0` on copy errors).
- **Fast Copy-on-Write (`CoW`)**: Clones matched files and whole directories (`node_modules/`, `.venv/`) using APFS `cp -c` on macOS and `cp --reflink=auto` on Linux/Windows when supported, falling back to permission-preserving `cp -P -p` (preserving symlinks without dereferencing).
- **Non-Destructive Hook Coexistence**: Chains cleanly alongside existing global or local `post-checkout` hooks (including `.husky` and `git-lfs`) and forwards all standard Git hooks to per-repository `.git/hooks/*`.

---

## Quick Start

### Install (1 command)

**macOS / Linux / WSL / Git Bash:**

```sh
curl -fsSL https://raw.githubusercontent.com/martinskuta/git-worktreeinclude-hook/main/git-worktreeinclude | sh -s -- install
```

**Windows PowerShell:**

```powershell
irm https://raw.githubusercontent.com/martinskuta/git-worktreeinclude-hook/main/install.ps1 | iex
```

Installing registers the `git worktreeinclude` Git subcommand, so `git worktreeinclude ...` works everywhere (`zsh`, `bash`, `fish`, `Git Bash`, `PowerShell`, `cmd.exe`) with **no `PATH` changes required**.

### Install from a Cloned Repository

**macOS / Linux / WSL / Git Bash:**

```sh
git clone https://github.com/martinskuta/git-worktreeinclude-hook.git
cd git-worktreeinclude-hook
sh git-worktreeinclude install
```

**Windows PowerShell:**

```powershell
git clone https://github.com/martinskuta/git-worktreeinclude-hook.git
cd git-worktreeinclude-hook
.\install.ps1
```

### Per-Repository Install (`--local`)

If you already ran the global install above, enable a specific repository locally (for example, a repo with its own `.husky` `core.hooksPath`) with:

```sh
git worktreeinclude install --local
```

Or install `--local` directly from GitHub without global setup:

```sh
# macOS / Linux / WSL / Git Bash (run inside the target repository)
curl -fsSL https://raw.githubusercontent.com/martinskuta/git-worktreeinclude-hook/main/git-worktreeinclude | sh -s -- install --local
```

```powershell
# Windows PowerShell (run inside the target repository)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/martinskuta/git-worktreeinclude-hook/main/install.ps1))) --local
```

### Uninstall (1 command)

```sh
git worktreeinclude uninstall
```

*(For per-repository installations:)*

```sh
git worktreeinclude uninstall --local
```

---

## `.worktreeinclude` Examples

Create a `.worktreeinclude` file in the root of your primary worktree (and optionally in subdirectories for monorepos). `.worktreeinclude` itself may be committed to Git, left untracked, or added to `.gitignore`.

```gitignore
# Copy local environment files at any depth, except production secrets
.env*
!.env.production

# Only at the repository root
/.npmrc
/docker-compose.override.yml

# Recursive globs
**/local.settings.json
config/**/local.yml

# Whole directories (fast single-call CoW clone when supported)
node_modules/
.venv/

# Empty runtime directories to pre-create in new worktrees
logs/
tmp/cache/
```

Now whenever you create a worktree:

```sh
git worktree add ../my-feature -b feat/my-feature
# worktreeinclude: copied 4 paths from primary worktree
```

Switching branches later inside `../my-feature` (`git switch`, `git checkout`) will **not** re-run the copy.

---

## CLI Reference

```text
git worktreeinclude install [--local] [--hooks-dir <dir>]
git worktreeinclude uninstall [--local]
git worktreeinclude apply [<worktree-path>] [--all] [--dry-run|-n] [--verbose|-v]
git worktreeinclude status
git worktreeinclude --version | --help
```

### Previewing & Backfilling (`apply`)

- **Preview rules before creating a worktree** (run inside the primary worktree):
  ```sh
  git worktreeinclude apply --dry-run
  ```
- **Backfill the current linked worktree** (e.g. after adding new patterns to `.worktreeinclude`):
  ```sh
  git worktreeinclude apply
  ```
- **Backfill a specific worktree or all linked worktrees**:
  ```sh
  git worktreeinclude apply ../my-feature
  git worktreeinclude apply --all
  ```
- **Inspect installation & discovered `.worktreeinclude` files**:
  ```sh
  git worktreeinclude status
  ```
- **Verbose logging** (for debugging hook or `apply` runs):
  ```sh
  GIT_WORKTREEINCLUDE_VERBOSE=1 git worktree add ../wt-debug -b debug
  ```

---

## How Hook Coexistence Works

- **Global install (default)**:
  - Installs the script to `${XDG_CONFIG_HOME:-~/.config}/git/worktreeinclude/git-worktreeinclude`.
  - If global `core.hooksPath` is **unset**, points it to `${XDG_CONFIG_HOME:-~/.config}/git/worktreeinclude/hooks` and generates lightweight passthrough stubs for all standard Git hooks so every repository's `.git/hooks/<hook>` (`pre-commit`, `commit-msg`, `pre-push`, `post-checkout`, etc.) continues running transparently.
  - If global `core.hooksPath` is **already set**, leaves your `core.hooksPath` untouched and injects a delimited `# >>> git-worktreeinclude >>>` block into its `post-checkout` hook.
  - Note: If an individual repository overrides `core.hooksPath` locally (for example, `.husky`), Git prioritizes local `core.hooksPath` over global `core.hooksPath`. Run `git worktreeinclude install --local` in that repository to chain into its local `post-checkout` hook (`git worktreeinclude status` detects and highlights this automatically).

---

## Running Tests

The repository includes an isolated end-to-end test suite (never modifies your real `$HOME` or `~/.gitconfig`):

```sh
sh ./tests/test_worktreeinclude.sh
```

---

## License

[MIT](./LICENSE)
