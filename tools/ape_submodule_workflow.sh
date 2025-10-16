#!/bin/sh
# POSIX shell utilities for managing ape's git submodules during feature work.

set -eu

COMMAND_NAME=$(basename "$0")
REPO_ROOT=""
INCLUDE_CLEAN=0
MODULES=""
MODULE_FILTER=""
VERBOSE=0

usage() {
    cat <<USAGE
Usage: $COMMAND_NAME [global options] <command> [command options]

Global options:
  --repo-root <path>      Path to the ape repository that hosts the submodules (default: current directory)
  --modules <names>       Comma-separated list of submodule names to operate on (default: dirty modules)
  --include-clean         Include clean submodules when running the status command
  --verbose               Enable debug logging
  -h, --help              Show this help message

Commands:
  status                  Show which submodules have local changes
  branch                  Create or checkout a feature branch inside dirty submodules
  push                    Push feature branches in dirty submodules
  mr                      Create merge/pull requests for feature branches in dirty submodules
  update-parent           Stage updated submodule hashes in the parent repository

Run "$COMMAND_NAME <command> --help" for help with a specific command.
USAGE
}

log_debug() {
    if [ "$VERBOSE" -eq 1 ]; then
        printf '[submodule-workflow] %s\n' "$1" >&2
    fi
}

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_argument() {
    opt="$1"
    shift
    if [ $# -eq 0 ] || [ "${1:-}" = "" ]; then
        die "Option $opt requires a value."
    fi
}

COMMAND=""

# Parse global options
while [ $# -gt 0 ]; do
    case "$1" in
        --repo-root)
            shift
            require_argument --repo-root "$@"
            REPO_ROOT="$1"
            shift
            ;;
        --modules)
            shift
            require_argument --modules "$@"
            MODULES="$1"
            shift
            ;;
        --include-clean)
            INCLUDE_CLEAN=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        status|branch|push|mr|update-parent)
            COMMAND="$1"
            shift
            break
            ;;
        --*)
            die "Unknown option: $1"
            ;;
        *)
            die "Unexpected argument: $1"
            ;;
    esac
done

if [ -z "$COMMAND" ]; then
    usage >&2
    exit 1
fi

if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT=$(pwd)
fi

REPO_ROOT=$(cd "$REPO_ROOT" 2>/dev/null && pwd) || die "Unable to access repository root: $REPO_ROOT"

if [ ! -f "$REPO_ROOT/.gitmodules" ]; then
    die "Expected to find a .gitmodules file in $REPO_ROOT; is this the ape repository?"
fi

if [ -n "$MODULES" ]; then
    MODULE_FILTER=$(printf '%s' "$MODULES" | tr ',:' ' ')
fi

RAW_CONFIG=$(mktemp)
SUBMODULE_CACHE=$(mktemp)
cleanup() {
    rm -f "$RAW_CONFIG" "$SUBMODULE_CACHE"
}
trap cleanup EXIT HUP INT TERM

if ! git -C "$REPO_ROOT" config --file .gitmodules --get-regexp '^submodule\..*\.path$' >"$RAW_CONFIG" 2>/dev/null; then
    :
fi

if [ ! -s "$RAW_CONFIG" ]; then
    printf 'No submodules registered in .gitmodules.\n'
    exit 0
fi

while IFS= read -r line; do
    key=${line%% *}
    rel_path=${line#* }
    [ -n "$key" ] || continue
    name=$(printf '%s\n' "$key" | sed 's/^submodule\."//; s/"\.path$//')
    if abs_path=$(cd "$REPO_ROOT/$rel_path" 2>/dev/null && pwd); then
        :
    else
        abs_path="$REPO_ROOT/$rel_path"
    fi
    printf '%s\t%s\t%s\n' "$name" "$abs_path" "$rel_path"
done <"$RAW_CONFIG" >"$SUBMODULE_CACHE"

if [ ! -s "$SUBMODULE_CACHE" ]; then
    printf 'No submodules registered in .gitmodules.\n'
    exit 0
fi

module_exists() {
    name="$1"
    if grep -F "${name}\t" "$SUBMODULE_CACHE" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

module_selected() {
    name="$1"
    if [ -z "$MODULE_FILTER" ]; then
        return 0
    fi
    for want in $MODULE_FILTER; do
        if [ "$want" = "$name" ]; then
            return 0
        fi
    done
    return 1
}

if [ -n "$MODULE_FILTER" ]; then
    for want in $MODULE_FILTER; do
        if ! module_exists "$want"; then
            die "Unknown submodule: $want"
        fi
    done
fi

current_branch() {
    path="$1"
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        printf '\n'
    else
        printf '%s\n' "$branch"
    fi
}

ensure_branch() {
    path="$1"
    branch="$2"
    base="$3"
    remote="$4"
    force_flag="$5"

    current=$(current_branch "$path")
    if [ "$current" = "$branch" ]; then
        printf '%s\n' "$branch"
        return 0
    fi

    if git -C "$path" rev-parse --verify "$branch" >/dev/null 2>&1; then
        log_debug "Branch $branch already exists in $path; checking out."
        git -C "$path" checkout "$branch" >/dev/null
        printf '%s\n' "$branch"
        return 0
    fi

    status=$(git -C "$path" status --porcelain 2>/dev/null || true)
    if [ -n "$base" ] && [ -z "$status" ]; then
        log_debug "Fetching $remote/$base in $path before creating $branch."
        git -C "$path" fetch "$remote" "$base" >/dev/null 2>&1 || true
        git -C "$path" checkout "$base" >/dev/null 2>&1 || true
        git -C "$path" pull "$remote" "$base" >/dev/null 2>&1 || true
    fi

    if [ "$force_flag" -eq 1 ]; then
        git -C "$path" checkout -B "$branch" >/dev/null
    else
        git -C "$path" checkout -b "$branch" >/dev/null
    fi
    printf '%s\n' "$branch"
}

push_branch() {
    path="$1"
    branch="$2"
    remote="$3"
    set_upstream="$4"

    if [ "$set_upstream" -eq 1 ]; then
        git -C "$path" push -u "$remote" "$branch"
    else
        git -C "$path" push "$remote" "$branch"
    fi
}

status_command() {
    include_clean="$1"
    found=0
    while IFS='\t' read -r name path rel; do
        module_selected "$name" || continue
        status=$(git -C "$path" status --porcelain 2>/dev/null || true)
        if [ -n "$status" ] || [ "$include_clean" -eq 1 ]; then
            found=1
            printf '%s (%s):\n' "$name" "$path"
            if [ -n "$status" ]; then
                printf '%s\n' "$status" | sed 's/^/  /'
            else
                printf '  clean\n'
            fi
        fi
    done <"$SUBMODULE_CACHE"

    if [ $found -eq 0 ]; then
        if [ "$include_clean" -eq 1 ]; then
            printf 'No submodules matched the provided filters.\n'
        else
            printf 'No dirty submodules detected.\n'
        fi
    fi
}

branch_command() {
    branch_name="$1"
    base="$2"
    remote="$3"
    force_flag="$4"

    found=0
    while IFS='\t' read -r name path rel; do
        module_selected "$name" || continue
        status=$(git -C "$path" status --porcelain 2>/dev/null || true)
        if [ -z "$status" ]; then
            continue
        fi
        found=1
        checked=$(ensure_branch "$path" "$branch_name" "$base" "$remote" "$force_flag")
        printf 'Checked out %s in %s (%s).\n' "$checked" "$name" "$path"
    done <"$SUBMODULE_CACHE"

    if [ $found -eq 0 ]; then
        printf 'No dirty submodules detected; nothing to branch.\n'
    fi
}

push_command() {
    remote="$1"
    set_upstream="$2"

    found=0
    while IFS='\t' read -r name path rel; do
        module_selected "$name" || continue
        status=$(git -C "$path" status --porcelain 2>/dev/null || true)
        if [ -z "$status" ]; then
            continue
        fi
        branch=$(current_branch "$path")
        if [ -z "$branch" ]; then
            die "Submodule $name is in a detached HEAD state; cannot push without a branch."
        fi
        found=1
        push_branch "$path" "$branch" "$remote" "$set_upstream"
        printf 'Pushed %s (%s) to %s/%s.\n' "$name" "$path" "$remote" "$branch"
    done <"$SUBMODULE_CACHE"

    if [ $found -eq 0 ]; then
        printf 'No dirty submodules detected; nothing to push.\n'
    fi
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

detect_mr_tool() {
    remote_url=$(lowercase "$1")
    if printf '%s' "$remote_url" | grep -q 'gitlab'; then
        if command -v glab >/dev/null 2>&1; then
            printf 'glab\n'
            return 0
        fi
    fi
    if printf '%s' "$remote_url" | grep -q 'github'; then
        if command -v gh >/dev/null 2>&1; then
            printf 'gh\n'
            return 0
        fi
    fi
    case "$remote_url" in
        *.git)
            if command -v gh >/dev/null 2>&1; then
                printf 'gh\n'
                return 0
            fi
            ;;
    esac
    if command -v glab >/dev/null 2>&1; then
        printf 'glab\n'
        return 0
    fi
    if command -v gh >/dev/null 2>&1; then
        printf 'gh\n'
        return 0
    fi
    printf '\n'
}

create_merge_request() {
    path="$1"
    branch="$2"
    target="$3"
    title="$4"
    draft="$5"

    remote_url=$(git -C "$path" remote get-url origin 2>/dev/null || printf '')
    tool=$(detect_mr_tool "$remote_url")
    if [ -z "$tool" ]; then
        printf 'No supported CLI (glab or gh) detected. Please create the merge request manually.\n' >&2
        if [ -n "$title" ]; then
            printf 'Suggested title: %s\n' "$title" >&2
        else
            printf 'Suggested title: %s\n' "$branch" >&2
        fi
        return 1
    fi

    if [ "$tool" = "glab" ]; then
        set -- glab mr create --source-branch "$branch" --target-branch "$target"
        if [ -n "$title" ]; then
            set -- "$@" --title "$title"
        fi
        if [ "$draft" -eq 1 ]; then
            set -- "$@" --draft
        fi
    else
        set -- gh pr create --head "$branch" --base "$target"
        if [ -n "$title" ]; then
            set -- "$@" --title "$title"
        fi
        if [ "$draft" -eq 1 ]; then
            set -- "$@" --draft
        fi
    fi

    log_debug "Running MR command: $*"
    if "$@"; then
        return 0
    fi
    return $?
}

mr_command() {
    target="$1"
    title="$2"
    draft="$3"

    found=0
    while IFS='\t' read -r name path rel; do
        module_selected "$name" || continue
        status=$(git -C "$path" status --porcelain 2>/dev/null || true)
        if [ -z "$status" ]; then
            continue
        fi
        branch=$(current_branch "$path")
        if [ -z "$branch" ]; then
            die "Submodule $name does not have an active branch; create one before opening an MR."
        fi
        found=1
        if create_merge_request "$path" "$branch" "$target" "$title" "$draft"; then
            printf 'Triggered merge request creation for %s (%s -> %s).\n' "$name" "$branch" "$target"
        else
            printf 'Skipped automated MR creation for %s; see message above.\n' "$name"
        fi
    done <"$SUBMODULE_CACHE"

    if [ $found -eq 0 ]; then
        printf 'No dirty submodules detected; no merge requests created.\n'
    fi
}

update_parent_command() {
    found=0
    while IFS='\t' read -r name path rel; do
        module_selected "$name" || continue
        status=$(git -C "$path" status --porcelain 2>/dev/null || true)
        if [ -z "$status" ]; then
            continue
        fi
        found=1
        git -C "$REPO_ROOT" add "$rel"
        printf 'Staged updated hash for %s (%s).\n' "$name" "$rel"
    done <"$SUBMODULE_CACHE"

    if [ $found -eq 0 ]; then
        printf 'No dirty submodules detected; nothing to stage in the parent.\n'
    fi
}

case "$COMMAND" in
    status)
        status_command "$INCLUDE_CLEAN"
        ;;
    branch)
        BRANCH_NAME=""
        BASE=""
        REMOTE="origin"
        FORCE=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --name)
                    shift
                    require_argument --name "$@"
                    BRANCH_NAME="$1"
                    shift
                    ;;
                --base)
                    shift
                    require_argument --base "$@"
                    BASE="$1"
                    shift
                    ;;
                --remote)
                    shift
                    require_argument --remote "$@"
                    REMOTE="$1"
                    shift
                    ;;
                --force)
                    FORCE=1
                    shift
                    ;;
                -h|--help)
                    cat <<HELP
Usage: $COMMAND_NAME [global options] branch --name <branch> [--base <base>] [--remote <remote>] [--force]
HELP
                    exit 0
                    ;;
                --*)
                    die "Unknown branch option: $1"
                    ;;
                *)
                    die "Unexpected branch argument: $1"
                    ;;
            esac
        done
        if [ -z "$BRANCH_NAME" ]; then
            die "--name is required for the branch command."
        fi
        branch_command "$BRANCH_NAME" "$BASE" "$REMOTE" "$FORCE"
        ;;
    push)
        REMOTE="origin"
        SET_UPSTREAM=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --remote)
                    shift
                    require_argument --remote "$@"
                    REMOTE="$1"
                    shift
                    ;;
                --set-upstream)
                    SET_UPSTREAM=1
                    shift
                    ;;
                -h|--help)
                    cat <<HELP
Usage: $COMMAND_NAME [global options] push [--remote <remote>] [--set-upstream]
HELP
                    exit 0
                    ;;
                --*)
                    die "Unknown push option: $1"
                    ;;
                *)
                    die "Unexpected push argument: $1"
                    ;;
            esac
        done
        push_command "$REMOTE" "$SET_UPSTREAM"
        ;;
    mr)
        TARGET="main"
        TITLE=""
        DRAFT=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --target)
                    shift
                    require_argument --target "$@"
                    TARGET="$1"
                    shift
                    ;;
                --title)
                    shift
                    require_argument --title "$@"
                    TITLE="$1"
                    shift
                    ;;
                --draft)
                    DRAFT=1
                    shift
                    ;;
                -h|--help)
                    cat <<HELP
Usage: $COMMAND_NAME [global options] mr [--target <branch>] [--title <title>] [--draft]
HELP
                    exit 0
                    ;;
                --*)
                    die "Unknown mr option: $1"
                    ;;
                *)
                    die "Unexpected mr argument: $1"
                    ;;
            esac
        done
        mr_command "$TARGET" "$TITLE" "$DRAFT"
        ;;
    update-parent)
        while [ $# -gt 0 ]; do
            case "$1" in
                -h|--help)
                    cat <<HELP
Usage: $COMMAND_NAME [global options] update-parent
HELP
                    exit 0
                    ;;
                --*)
                    die "Unknown update-parent option: $1"
                    ;;
                *)
                    die "Unexpected update-parent argument: $1"
                    ;;
            esac
        done
        update_parent_command
        ;;
    *)
        die "Unknown command: $COMMAND"
        ;;
esac
