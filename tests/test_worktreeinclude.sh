#!/bin/sh
# End-to-end integration test suite for git-worktreeinclude
# Runs in a completely isolated HOME / GIT_CONFIG_GLOBAL sandbox.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
WTI_BIN="$REPO_ROOT/git-worktreeinclude"

TEST_BASE="${TMPDIR:-/tmp}"
TEST_BASE="${TEST_BASE%/}"
SANDBOX=$(mktemp -d "$TEST_BASE/wti-e2e.XXXXXX" 2>/dev/null || (d="$TEST_BASE/wti-e2e.$$"; mkdir -p "$d" && printf '%s' "$d"))

cleanup_sandbox() {
    cd / 2>/dev/null || true
    rm -rf "$SANDBOX" 2>/dev/null || true
}
trap 'cleanup_sandbox' EXIT INT TERM HUP

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""

fail() {
    printf '  [FAIL] %s: %s\n' "$CURRENT_TEST" "$*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    exit 1
}

assert_eq() {
    expected="$1"
    actual="$2"
    msg="${3:-expected '$expected', got '$actual'}"
    if [ "$expected" != "$actual" ]; then
        fail "$msg"
    fi
}

assert_file_exists() {
    if [ ! -f "$1" ]; then
        fail "expected regular file to exist: $1"
    fi
}

assert_dir_exists() {
    if [ ! -d "$1" ]; then
        fail "expected directory to exist: $1"
    fi
}

assert_not_exists() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "expected path NOT to exist: $1"
    fi
}

assert_file_content() {
    file_p="$1"
    expected_c="$2"
    assert_file_exists "$file_p"
    actual_c=$(tr -d '\r' < "$file_p")
    if [ "$actual_c" != "$expected_c" ]; then
        fail "content mismatch in $file_p: expected '$expected_c', got '$actual_c'"
    fi
}

assert_contains() {
    haystack="$1"
    needle="$2"
    case "$haystack" in
        *"$needle"*) ;;
        *) fail "expected output to contain '$needle', got: $haystack" ;;
    esac
}

# Set up fresh isolated HOME + git config for a test case
setup_env() {
    t_id="$1"
    T_DIR="$SANDBOX/$t_id"
    mkdir -p "$T_DIR/home" "$T_DIR/xdg" "$T_DIR/work"
    HOME="$T_DIR/home"
    XDG_CONFIG_HOME="$T_DIR/xdg"
    GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    GIT_CONFIG_NOSYSTEM=1
    export HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_WORKTREEINCLUDE_VERBOSE || true

    git config --global user.name "Test User"
    git config --global user.email "test@example.com"
    git config --global init.defaultBranch main
    git config --global core.autocrlf false
}

init_repo() {
    r_dir="$1"
    mkdir -p "$r_dir"
    git -C "$r_dir" init -q
    printf 'base tracked content\n' > "$r_dir/README.md"
    git -C "$r_dir" add README.md
    git -C "$r_dir" commit -q -m "initial commit"
}

TEST_FILTER="${1:-}"

run_test() {
    t_name="$1"
    t_fn="$2"
    if [ -n "$TEST_FILTER" ]; then
        case "$t_name" in
            *"$TEST_FILTER"*) ;;
            *) return 0 ;;
        esac
    fi
    CURRENT_TEST="$t_name"
    printf 'RUN  %s\n' "$t_name"
    (
        set -eu
        "$t_fn"
    )
    printf 'PASS %s\n' "$t_name"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# ---------------------------------------------------------------------------
# Test 1: 1-command Global Install, Automatic Hook on git worktree add, 1-command Uninstall
# ---------------------------------------------------------------------------
test_global_install_and_uninstall() {
    setup_env "t1"
    sh "$WTI_BIN" install

    # Alias works from anywhere (even outside a git repo)
    ver_out=$(git worktreeinclude --version)
    assert_contains "$ver_out" "git-worktreeinclude"

    stat_out=$(git worktreeinclude status)
    assert_contains "$stat_out" "global hook:      yes"

    # Idempotent re-install via git alias itself (must not self-truncate!)
    git worktreeinclude install
    assert_file_exists "$XDG_CONFIG_HOME/git/worktreeinclude/git-worktreeinclude"

    # Create repo with .worktreeinclude
    repo="$T_DIR/work/repo1"
    init_repo "$repo"
    printf '.env*\n' > "$repo/.gitignore"
    git -C "$repo" add .gitignore
    git -C "$repo" commit -q -m "add gitignore"

    printf 'API_KEY=secret123\n' > "$repo/.env"
    printf 'PORT=3000\n' > "$repo/.env.local"
    printf 'UNMATCHED=1\n' > "$repo/notes.tmp"
    printf '.env*\n' > "$repo/.worktreeinclude"

    wt2="$T_DIR/work/wt2"
    hook_stderr=$(git -C "$repo" worktree add -q -b feat-1 "$wt2" 2>&1)
    assert_contains "$hook_stderr" "worktreeinclude: copied 2 paths from primary worktree"

    assert_file_content "$wt2/.env" "API_KEY=secret123"
    assert_file_content "$wt2/.env.local" "PORT=3000"
    assert_not_exists "$wt2/notes.tmp"
    assert_not_exists "$wt2/.worktreeinclude"

    # Subsequent branch switches inside wt2 must NOT re-copy deleted files
    rm -f "$wt2/.env.local"
    git -C "$wt2" checkout -q -b feat-2
    assert_not_exists "$wt2/.env.local"

    # Creating wt3 from INSIDE linked worktree wt2 still copies from PRIMARY worktree (repo)
    printf 'FROM_PRIMARY=yes\n' > "$repo/.env.local"
    wt3="$T_DIR/work/wt3"
    git -C "$wt2" worktree add -q -b feat-3 "$wt3"
    assert_file_content "$wt3/.env.local" "FROM_PRIMARY=yes"

    # 1-command uninstall cleans up hook, alias, core.hooksPath, and managed dir
    git worktreeinclude uninstall
    if git config --global --get alias.worktreeinclude >/dev/null 2>&1; then
        fail "alias.worktreeinclude should be unset after uninstall"
    fi
    if git config --global --get core.hooksPath >/dev/null 2>&1; then
        fail "core.hooksPath should be unset after uninstall"
    fi
    assert_not_exists "$XDG_CONFIG_HOME/git/worktreeinclude/git-worktreeinclude"

    # New worktree after uninstall should NOT copy .env
    wt4="$T_DIR/work/wt4"
    git -C "$repo" worktree add -q -b feat-4 "$wt4"
    assert_not_exists "$wt4/.env"
}

# ---------------------------------------------------------------------------
# Test 2: Per-repository (--local) install & uninstall + custom local core.hooksPath (.husky)
# ---------------------------------------------------------------------------
test_local_install_and_husky_coexistence() {
    setup_env "t2"
    repo="$T_DIR/work/repo_local"
    init_repo "$repo"

    # Simulate repo with local core.hooksPath = .husky and an existing post-checkout hook ending with exit 0
    mkdir -p "$repo/.husky"
    cat > "$repo/.husky/post-checkout" <<EOF
#!/bin/sh
printf 'husky-ran\n' >> "$T_DIR/husky.log"
exit 0
EOF
    chmod +x "$repo/.husky/post-checkout"
    cp "$repo/.husky/post-checkout" "$T_DIR/husky.orig"
    git -C "$repo" config --local core.hooksPath .husky

    (cd "$repo" && sh "$WTI_BIN" install --local)

    # Global config must remain completely untouched
    if git config --global --get alias.worktreeinclude >/dev/null 2>&1; then
        fail "global alias must not be modified by --local install"
    fi
    assert_not_exists "$XDG_CONFIG_HOME/git/worktreeinclude"

    printf 'LOCAL_ONLY=true\n' > "$repo/.env"
    printf '.env\n' > "$repo/.worktreeinclude"

    wt_loc="$T_DIR/work/wt_local"
    git -C "$repo" worktree add -q -b branch-loc "$wt_loc"

    # Both git-worktreeinclude AND .husky/post-checkout (despite exit 0!) must have executed
    assert_file_content "$wt_loc/.env" "LOCAL_ONLY=true"
    assert_file_exists "$T_DIR/husky.log"

    # Uninstall --local via git alias inside repo restores .husky/post-checkout byte-for-byte
    git -C "$repo" worktreeinclude uninstall --local
    orig_c=$(tr -d '\r' < "$T_DIR/husky.orig")
    restored_c=$(tr -d '\r' < "$repo/.husky/post-checkout")
    assert_eq "$orig_c" "$restored_c" ".husky/post-checkout should be restored verbatim"
    assert_eq ".husky" "$(git -C "$repo" config --local --get core.hooksPath)"
}

# ---------------------------------------------------------------------------
# Test 3: Complete .gitignore syntax parity (#comments, CRLF, !, /, **, escapes, trailing spaces, dir/)
# ---------------------------------------------------------------------------
test_full_gitignore_semantics() {
    setup_env "t3"
    sh "$WTI_BIN" install

    repo="$T_DIR/work/repo_syntax"
    init_repo "$repo"

    mkdir -p "$repo/sub" "$repo/config/nested" "$repo/deep/a/b" "$repo/onlydir" "$repo/empty_match" "$repo/empty_skip"
    printf 'not-a-dir\n' > "$repo/onlyfile_dirrule"

    printf '1\n' > "$repo/root_anchor.env"
    printf '2\n' > "$repo/sub/root_anchor.env"
    printf '3\n' > "$repo/unanchored.local"
    printf '4\n' > "$repo/sub/unanchored.local"
    printf '5\n' > "$repo/config/keep.cfg"
    printf '6\n' > "$repo/config/skip.cfg"
    printf '7\n' > "$repo/config/reinclude.cfg"
    printf '8\n' > "$repo/deep/a/b/target.json"
    printf '9\n' > "$repo/!literal_bang.txt"
    printf '10\n' > "$repo/#literal_hash.txt"
    printf '11\n' > "$repo/with space.txt"
    printf '12\n' > "$repo/char_5.dat"
    printf '13\n' > "$repo/char_x.dat"
    printf '14\n' > "$repo/onlydir/inside.txt"

    # Write .worktreeinclude WITH CRLF (\r\n) to verify CRLF resilience too
    awk 'BEGIN { ORS="\r\n" } { print }' > "$repo/.worktreeinclude" <<'EOF'
# Comment line should be ignored

/root_anchor.env
*.local
config/*.cfg
!config/*.cfg
config/keep.cfg
config/reinclude.cfg
**/target.json
\!literal_bang.txt
\#literal_hash.txt
with\ space.txt   
char_[0-9].dat
onlydir/
onlyfile_dirrule/
empty_match/
EOF

    wt="$T_DIR/work/wt_syntax"
    git -C "$repo" worktree add -q -b syntax-branch "$wt"

    assert_file_content "$wt/root_anchor.env" "1"
    assert_not_exists "$wt/sub/root_anchor.env"
    assert_file_content "$wt/unanchored.local" "3"
    assert_file_content "$wt/sub/unanchored.local" "4"
    assert_file_content "$wt/config/keep.cfg" "5"
    assert_not_exists "$wt/config/skip.cfg"
    assert_file_content "$wt/config/reinclude.cfg" "7"
    assert_file_content "$wt/deep/a/b/target.json" "8"
    assert_file_content "$wt/!literal_bang.txt" "9"
    assert_file_content "$wt/#literal_hash.txt" "10"
    assert_file_content "$wt/with space.txt" "11"
    assert_file_content "$wt/char_5.dat" "12"
    assert_not_exists "$wt/char_x.dat"
    assert_file_content "$wt/onlydir/inside.txt" "14"
    assert_not_exists "$wt/onlyfile_dirrule"
    assert_dir_exists "$wt/empty_match"
    assert_not_exists "$wt/empty_skip"
}

# ---------------------------------------------------------------------------
# Test 4: Hierarchical nested .worktreeinclude + vendor dir skipping + tracked/untracked/ignored .worktreeinclude
# ---------------------------------------------------------------------------
test_hierarchical_and_ignored_vendor_skip() {
    setup_env "t4"
    sh "$WTI_BIN" install

    repo="$T_DIR/work/repo_hier"
    init_repo "$repo"

    mkdir -p "$repo/apps/web/sub" "$repo/apps/api" "$repo/node_modules/evil_pkg" "$repo/dist/evil_pkg2"
    printf 'console.log(1);\n' > "$repo/apps/web/app.js"

    cat > "$repo/.gitignore" <<'EOF'
.worktreeinclude
node_modules/
dist/*
*.env
EOF
    git -C "$repo" add .gitignore apps/web/app.js

    # Root .worktreeinclude is Git-ignored by .gitignore
    cat > "$repo/.worktreeinclude" <<'EOF'
*.env
EOF
    # apps/web/.worktreeinclude is Force-Tracked in git
    cat > "$repo/apps/web/.worktreeinclude" <<'EOF'
!skip_me.env
/root_web.cfg
sub/*.json
EOF
    git -C "$repo" add -f apps/web/.worktreeinclude
    git -C "$repo" commit -q -m "setup monorepo"

    # apps/api/.worktreeinclude is inside an untracked non-ignored dir, while .worktreeinclude itself is ignored
    cat > "$repo/apps/api/.worktreeinclude" <<'EOF'
*.key
EOF

    # Stray .worktreeinclude files inside ignored vendor/build directories MUST NOT be loaded!
    printf '*\n' > "$repo/node_modules/evil_pkg/.worktreeinclude"
    printf 'SHOULD_NOT_COPY\n' > "$repo/node_modules/evil_pkg/hack.txt"
    printf '*\n' > "$repo/dist/evil_pkg2/.worktreeinclude"
    printf 'SHOULD_NOT_COPY_2\n' > "$repo/dist/evil_pkg2/hack2.txt"

    # Populate candidate files (both git-ignored .env and untracked-unignored .cfg/.json/.key)
    printf 'root-env\n' > "$repo/.env"
    printf 'web-env\n' > "$repo/apps/web/.env"
    printf 'web-skip\n' > "$repo/apps/web/skip_me.env"
    printf 'web-sub-skip\n' > "$repo/apps/web/sub/skip_me.env"
    printf 'web-root-cfg\n' > "$repo/apps/web/root_web.cfg"
    printf 'web-sub-cfg\n' > "$repo/apps/web/sub/root_web.cfg"
    printf '{"ok":true}\n' > "$repo/apps/web/sub/data.json"
    printf 'api-secret\n' > "$repo/apps/api/service.key"

    wt="$T_DIR/work/wt_hier"
    git -C "$repo" worktree add -q -b mono-feat "$wt"

    assert_file_content "$wt/.env" "root-env"
    assert_file_content "$wt/apps/web/.env" "web-env"
    assert_not_exists "$wt/apps/web/skip_me.env"
    assert_not_exists "$wt/apps/web/sub/skip_me.env"
    assert_file_content "$wt/apps/web/root_web.cfg" "web-root-cfg"
    assert_not_exists "$wt/apps/web/sub/root_web.cfg"
    assert_file_content "$wt/apps/web/sub/data.json" '{"ok":true}'
    assert_file_content "$wt/apps/api/service.key" "api-secret"
    assert_not_exists "$wt/node_modules/evil_pkg/hack.txt"
    assert_not_exists "$wt/dist/evil_pkg2/hack2.txt"
}

# ---------------------------------------------------------------------------
# Test 5: Hard safety invariants (never touch tracked files, never overwrite, never delete, skip nested .git)
# ---------------------------------------------------------------------------
test_safety_invariants_and_nested_git() {
    setup_env "t5"
    sh "$WTI_BIN" install

    repo="$T_DIR/work/repo_safe"
    init_repo "$repo"

    # Create a branch 'other-branch' that tracks 'branch_tracked.txt' and 'shared_dir/tracked_in_branch.txt'
    git -C "$repo" checkout -q -b other-branch
    mkdir -p "$repo/shared_dir"
    printf 'tracked-on-other-branch\n' > "$repo/branch_tracked.txt"
    printf 'tracked-inside-dir\n' > "$repo/shared_dir/tracked_in_branch.txt"
    git -C "$repo" add branch_tracked.txt shared_dir/tracked_in_branch.txt
    git -C "$repo" commit -q -m "branch-specific tracked files"

    # Switch primary worktree back to main where those files are NOT tracked
    git -C "$repo" checkout -q main

    # Create untracked files in main at the exact same paths + dirty edit to README.md + nested .git repo
    printf 'DIRTY_MAIN_README\n' > "$repo/README.md"
    printf 'untracked-in-main-would-collide\n' > "$repo/branch_tracked.txt"
    mkdir -p "$repo/shared_dir"
    printf 'untracked-in-main-dir-collide\n' > "$repo/shared_dir/tracked_in_branch.txt"
    printf 'safe-untracked-sibling\n' > "$repo/shared_dir/extra.local"
    printf 'initial-val\n' > "$repo/config.local"

    # Embedded untracked git repository
    mkdir -p "$repo/embedded_repo"
    git -C "$repo/embedded_repo" init -q
    printf 'foreign\n' > "$repo/embedded_repo/file.txt"

    # Match EVERYTHING (*) in .worktreeinclude — ultimate stress test for safety!
    cat > "$repo/.worktreeinclude" <<'EOF'
*
shared_dir/
embedded_repo/
EOF

    wt="$T_DIR/work/wt_safe"
    git -C "$repo" worktree add -q "$wt" other-branch

    # 1. README.md in wt must have clean committed content, NOT dirty main README.md!
    assert_file_content "$wt/README.md" "base tracked content"
    # 2. Tracked files on other-branch must NOT be overwritten by untracked files of same name in main!
    assert_file_content "$wt/branch_tracked.txt" "tracked-on-other-branch"
    assert_file_content "$wt/shared_dir/tracked_in_branch.txt" "tracked-inside-dir"
    # 3. Missing untracked sibling inside shared_dir/ WAS backfilled safely!
    assert_file_content "$wt/shared_dir/extra.local" "safe-untracked-sibling"
    assert_file_content "$wt/config.local" "initial-val"
    # 4. Embedded git repository was skipped!
    assert_not_exists "$wt/embedded_repo"
    # 5. git status of tracked files in wt must be 100% clean!
    dirty_tracked=$(git -C "$wt" diff --name-only HEAD)
    assert_eq "" "$dirty_tracked" "tracked files in target worktree must remain completely unmodified"

    # 6. Never overwrite existing files & never delete target-only files on manual apply
    printf 'custom-wt-edit\n' > "$wt/config.local"
    printf 'wt-only-file\n' > "$wt/keep_me.txt"
    printf 'updated-in-main\n' > "$repo/config.local"
    printf 'newly-added-in-main\n' > "$repo/new_item.local"

    git -C "$wt" worktreeinclude apply
    assert_file_content "$wt/config.local" "custom-wt-edit"
    assert_file_content "$wt/keep_me.txt" "wt-only-file"
    assert_file_content "$wt/new_item.local" "newly-added-in-main"
}

# ---------------------------------------------------------------------------
# Test 6: Symlinks, whole-directory CoW + partial backfill, permissions, Unicode & spaces
# ---------------------------------------------------------------------------
test_symlinks_cow_permissions_and_unicode() {
    setup_env "t6"
    sh "$WTI_BIN" install

    repo="$T_DIR/work/repo_cow"
    init_repo "$repo"

    mkdir -p "$repo/vendor_cache/pkg_a" "$repo/bin_scripts"
    printf 'pkg-a-v1\n' > "$repo/vendor_cache/pkg_a/index.js"
    printf '#!/bin/sh\necho hi\n' > "$repo/bin_scripts/run.sh"
    chmod +x "$repo/bin_scripts/run.sh"
    printf 'UTF8=ok\n' > "$repo/český config.env"

    # Test symlink preservation if platform/filesystem allows creating symlinks without elevation
    symlink_supported=0
    if ln -s "../pkg_a/index.js" "$repo/vendor_cache/link_to_idx" 2>/dev/null && [ -L "$repo/vendor_cache/link_to_idx" ]; then
        symlink_supported=1
        ln -s "nonexistent_target_xyz" "$repo/dangling_link" 2>/dev/null || true
    fi

    cat > "$repo/.worktreeinclude" <<'EOF'
vendor_cache/
bin_scripts/
*.env
dangling_link
EOF

    wt="$T_DIR/work/wt_cow"
    git -C "$repo" worktree add -q -b cow-branch "$wt"

    assert_file_content "$wt/vendor_cache/pkg_a/index.js" "pkg-a-v1"
    assert_file_content "$wt/český config.env" "UTF8=ok"
    if [ ! -x "$wt/bin_scripts/run.sh" ]; then
        fail "expected executable permission to be preserved on bin_scripts/run.sh"
    fi
    if [ "$symlink_supported" = "1" ]; then
        if [ ! -L "$wt/vendor_cache/link_to_idx" ]; then
            fail "expected vendor_cache/link_to_idx to remain a symbolic link"
        fi
        if [ -L "$repo/dangling_link" ] && [ ! -L "$wt/dangling_link" ]; then
            fail "expected dangling_link to be copied as symbolic link"
        fi
    fi

    # Mutate wt's copy to prove isolation (CoW / copy, NOT shared hardlink/dir-symlink)
    printf 'wt-mutated\n' > "$wt/vendor_cache/pkg_a/index.js"
    assert_file_content "$repo/vendor_cache/pkg_a/index.js" "pkg-a-v1"

    # Add a new package in main's vendor_cache/ and run apply -> partial backfill copies pkg_b without touching pkg_a!
    mkdir -p "$repo/vendor_cache/pkg_b"
    printf 'pkg-b-new\n' > "$repo/vendor_cache/pkg_b/main.js"
    git -C "$wt" worktreeinclude apply
    assert_file_content "$wt/vendor_cache/pkg_b/main.js" "pkg-b-new"
    assert_file_content "$wt/vendor_cache/pkg_a/index.js" "wt-mutated"
}

# ---------------------------------------------------------------------------
# Test 7: Bare repository layout (git clone --bare) & --no-checkout worktrees
# ---------------------------------------------------------------------------
test_bare_repo_and_no_checkout() {
    setup_env "t7"
    sh "$WTI_BIN" install

    src_repo="$T_DIR/work/src_repo"
    init_repo "$src_repo"

    bare_repo="$T_DIR/work/project.git"
    git clone -q --bare "$src_repo" "$bare_repo"

    # First non-bare worktree becomes the primary worktree
    wt_primary="$T_DIR/work/wt_primary"
    git -C "$bare_repo" worktree add -q "$wt_primary" main
    printf 'BARE_PRIMARY_ENV=42\n' > "$wt_primary/.env"
    printf '.env\n' > "$wt_primary/.worktreeinclude"

    # Second worktree created from bare repo must pull from wt_primary!
    wt_second="$T_DIR/work/wt_second"
    git -C "$bare_repo" worktree add -q -b bare-feat "$wt_second" main
    assert_file_content "$wt_second/.env" "BARE_PRIMARY_ENV=42"

    # --no-checkout worktree: post-checkout does not run on --no-checkout; manual apply populates it safely before checkout
    wt_nc="$T_DIR/work/wt_nocheckout"
    git -C "$wt_primary" worktree add -q --no-checkout -b nc-feat "$wt_nc"
    assert_not_exists "$wt_nc/.env"

    git -C "$wt_primary" worktreeinclude apply "$wt_nc"
    assert_file_content "$wt_nc/.env" "BARE_PRIMARY_ENV=42"

    # Subsequent checkout inside --no-checkout worktree populates tracked files cleanly alongside .env
    git -C "$wt_nc" checkout -q nc-feat
    assert_file_content "$wt_nc/README.md" "base tracked content"
    assert_file_content "$wt_nc/.env" "BARE_PRIMARY_ENV=42"
}

# ---------------------------------------------------------------------------
# Test 8: Existing global hooks coexistence & local .git/hooks/* passthrough (incl. pre-push stdin)
# ---------------------------------------------------------------------------
test_hook_chaining_and_local_passthrough() {
    setup_env "t8"

    # Scenario A: Fresh global install must forward local .git/hooks/pre-commit and pre-push (with stdin!)
    sh "$WTI_BIN" install
    repo="$T_DIR/work/repo_hooks"
    init_repo "$repo"

    cat > "$repo/.git/hooks/pre-commit" <<EOF
#!/bin/sh
printf 'local-pre-commit-ran\n' > "$T_DIR/pre_commit.ran"
EOF
    chmod +x "$repo/.git/hooks/pre-commit"

    cat > "$repo/.git/hooks/pre-push" <<EOF
#!/bin/sh
cat > "$T_DIR/pre_push.stdin"
EOF
    chmod +x "$repo/.git/hooks/pre-push"

    cat > "$repo/.git/hooks/post-checkout" <<EOF
#!/bin/sh
printf 'local-post-checkout-ran\n' >> "$T_DIR/local_post_checkout.ran"
EOF
    chmod +x "$repo/.git/hooks/post-checkout"

    printf 'change\n' >> "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "trigger local pre-commit via global passthrough"
    assert_file_content "$T_DIR/pre_commit.ran" "local-pre-commit-ran"

    # Verify pre-push passthrough preserves stdin
    global_hp=$(git config --global --get core.hooksPath)
    printf 'refs/heads/main 1234 refs/heads/main 0000\n' | (cd "$repo" && sh "$global_hp/pre-push" origin https://example.invalid/repo.git)
    assert_file_content "$T_DIR/pre_push.stdin" "refs/heads/main 1234 refs/heads/main 0000"

    # Verify worktree add runs BOTH git-worktreeinclude AND local .git/hooks/post-checkout
    printf 'CHAIN=ok\n' > "$repo/.env"
    printf '.env\n' > "$repo/.worktreeinclude"
    wt_a="$T_DIR/work/wt_chain_a"
    git -C "$repo" worktree add -q -b chain-a "$wt_a"
    assert_file_content "$wt_a/.env" "CHAIN=ok"
    assert_file_exists "$T_DIR/local_post_checkout.ran"

    git worktreeinclude uninstall

    # Scenario B: User ALREADY has a custom global core.hooksPath with their own post-checkout
    user_ghooks="$T_DIR/user_global_hooks"
    mkdir -p "$user_ghooks"
    cat > "$user_ghooks/post-checkout" <<EOF
#!/bin/sh
printf 'user-global-hook:%s\n' "\$2" >> "$T_DIR/user_global.log"
exit 0
EOF
    chmod +x "$user_ghooks/post-checkout"
    cp "$user_ghooks/post-checkout" "$T_DIR/user_global.orig"
    git config --global core.hooksPath "$user_ghooks"
    expected_user_ghp=$(git config --global --get core.hooksPath)

    sh "$WTI_BIN" install
    wt_b="$T_DIR/work/wt_chain_b"
    git -C "$repo" worktree add -q -b chain-b "$wt_b"
    assert_file_content "$wt_b/.env" "CHAIN=ok"
    assert_file_exists "$T_DIR/user_global.log"

    # Uninstall must keep user's core.hooksPath and restore user's post-checkout verbatim
    git worktreeinclude uninstall
    assert_eq "$expected_user_ghp" "$(git config --global --get core.hooksPath)"
    assert_eq "$(tr -d '\r' < "$T_DIR/user_global.orig")" "$(tr -d '\r' < "$user_ghooks/post-checkout")"
}

# ---------------------------------------------------------------------------
# Test 9: Manual CLI (apply --dry-run in primary & linked, apply <rel-path> from subdir, apply --all, status)
# ---------------------------------------------------------------------------
test_cli_apply_dryrun_all_and_subdir_prefix() {
    setup_env "t9"
    sh "$WTI_BIN" install

    repo="$T_DIR/work/repo_cli"
    init_repo "$repo"
    mkdir -p "$repo/packages/subpkg"
    printf 'sub\n' > "$repo/packages/subpkg/tracked.txt"
    git -C "$repo" add packages/subpkg/tracked.txt
    git -C "$repo" commit -q -m "add subpkg"

    printf 'A=1\n' > "$repo/a.env"
    printf 'B=2\n' > "$repo/b.env"
    printf '*.env\n' > "$repo/.worktreeinclude"

    # 1. apply --dry-run inside primary worktree previews matched candidates
    dry_primary=$(git -C "$repo" worktreeinclude apply --dry-run)
    assert_contains "$dry_primary" "a.env"
    assert_contains "$dry_primary" "b.env"

    # 2. apply without --dry-run inside primary worktree is a safe no-op (exit 0)
    git -C "$repo" worktreeinclude apply

    wt1="$T_DIR/work/wt_cli_1"
    wt2="$T_DIR/work/wt_cli_2"
    git -C "$repo" worktree add -q -b cli-1 "$wt1"
    git -C "$repo" worktree add -q -b cli-2 "$wt2"

    # Add c.env AFTER wt1 & wt2 already exist
    printf 'C=3\n' > "$repo/c.env"

    # 3. Dry-run inside wt1 shows ONLY missing c.env (not already-existing a.env/b.env!)
    dry_linked=$(git -C "$wt1" worktreeinclude apply --dry-run)
    assert_eq "c.env" "$dry_linked"
    assert_not_exists "$wt1/c.env"

    # 4. Run apply <relative-path> from INSIDE a subdirectory of repo (verifies GIT_PREFIX restoration!)
    (cd "$repo/packages/subpkg" && git worktreeinclude apply "../../../wt_cli_1")
    assert_file_content "$wt1/c.env" "C=3"
    assert_not_exists "$wt2/c.env"

    # 5. Run apply --all to backfill remaining worktrees (wt2)
    git -C "$repo" worktreeinclude apply --all
    assert_file_content "$wt2/c.env" "C=3"

    # 6. Invalid CLI invocations exit non-zero
    if git -C "$repo" worktreeinclude apply --nonexistent-flag 2>/dev/null; then
        fail "expected unknown flag to exit non-zero"
    fi
    if git -C "$repo" worktreeinclude apply "$T_DIR/does-not-exist" 2>/dev/null; then
        fail "expected missing target worktree path to exit non-zero"
    fi
}

run_test "global install, hook trigger, branch switch no-op & 1-command uninstall" test_global_install_and_uninstall
run_test "local --local install/uninstall & .husky post-checkout coexistence" test_local_install_and_husky_coexistence
run_test "full .gitignore syntax parity (#, CRLF, !, /, **, escapes, dir/, empty dir)" test_full_gitignore_semantics
run_test "hierarchical nested .worktreeinclude & ignored vendor dir skipping" test_hierarchical_and_ignored_vendor_skip
run_test "safety invariants (zero tracked touch, zero overwrite, zero delete, nested .git)" test_safety_invariants_and_nested_git
run_test "symlinks, CoW directory cloning, partial backfill, permissions & UTF-8" test_symlinks_cow_permissions_and_unicode
run_test "bare repository layout & --no-checkout worktree support" test_bare_repo_and_no_checkout
run_test "global hook chaining & local .git/hooks/* passthrough (incl. pre-push stdin)" test_hook_chaining_and_local_passthrough
run_test "CLI apply, --dry-run (primary & linked), --all, GIT_PREFIX & error codes" test_cli_apply_dryrun_all_and_subdir_prefix

printf '\nAll %s end-to-end test suites passed!\n' "$PASS_COUNT"
