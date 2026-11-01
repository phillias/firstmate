#!/usr/bin/env bash
# Pre-register a worker harness's folder trust, supervisor-side, for the
# isolated task worktree a ship/scout spawn is about to launch into, so the
# worker reaches its brief instead of parking on a first-run trust dialog
# firstmate cannot answer.
#
# Usage: fm-worker-trust.sh <harness> <worktree> <project>
#   <harness>   an exact verified harness name; grok is the one supported today
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the project checkout that worktree belongs to (the primary
#               checkout, or a linked worktree of it)
# The store is read from this process's environment, so bin/fm-spawn.sh runs the
# helper with exactly the HOME and harness home variables the worker will see.
# Prints one line naming what it registered; refuses loudly on anything else.
# Exit 0 registered (or already registered), 1 refused, 2 usage. A refusal,
# including a host without python 3.11+ to read the store with, stops the
# spawn: there is no warning-only path.
#
# WHY THIS EXISTS. Every task worktree is a path the harness has never seen, and
# the operator can pre-register only directories they open by hand. Each
# supported harness keeps the decision in a store the launching user owns and
# honours an entry written ahead of launch (verified live under a throwaway
# home, docs/verification/worker-trust.md):
#   grok   ${GROK_HOME:-$HOME/.grok}/trusted_folders.toml, a [folders."<path>"]
#          table with trusted = true. grok keys the decision on the resolved git
#          root, which for a linked worktree is the PRIMARY CHECKOUT: an entry
#          for the worktree path alone is ignored, so the primary checkout is
#          what this records - exactly what answering the dialog writes.
# An entry is never consent the operator did not give elsewhere: an existing
# entry that records a decline (grok trusted other than true) is refused rather
# than overridden.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-claude-trust.sh and
# bin/fm-agy-trust.sh: <worktree> must be a LINKED git worktree - its own git
# dir, sharing <project>'s common dir - whose top level is exactly the resolved
# argument. A primary checkout, a worktree of an unrelated repo, a subdirectory
# of a worktree, a plain directory, and a home directory are each refused with a
# non-zero exit, never a warning and never a silent skip. When <project> is
# itself a linked worktree, its primary checkout is derived from the shared
# common dir and verified, as bin/fm-claude-trust.sh does. Only the launching
# user's own store is written, it must be a regular file this uid owns, the new
# table is appended so every existing byte is preserved, the result must parse
# to the original document plus that one entry, and the replacement is atomic
# under a lock the kernel releases when this process exits.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-worker-trust.sh <harness> <worktree> <project>" >&2
  echo "       <harness> is an exact verified harness name: grok" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
HARNESS=$1
WT_ARG=$2
PROJ_ARG=$3
case "$HARNESS" in
  grok) ;;
  *) usage ;;
esac

refuse() { echo "error: refusing to pre-register $HARNESS trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

git_dir_of() {
  local dir
  dir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  real_dir "$dir"
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ -n "${HOME:-}" ] || refuse "HOME is not set, so the trust store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"
for candidate in "$WT_REAL" "$PROJ_REAL"; do
  [ "$candidate" != / ] || refuse "'/' is the filesystem root, not a worktree or project"
  [ "$candidate" != "$HOME_REAL" ] || refuse "'$candidate' is the home directory, not a worktree or project"
done

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"
WT_GIT_DIR=$(git_dir_of "$WT_REAL") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_TOP=$(git -C "$PROJ_REAL" rev-parse --show-toplevel 2>/dev/null) || true
PROJ_TOP_REAL=
[ -z "$PROJ_TOP" ] || PROJ_TOP_REAL=$(real_dir "$PROJ_TOP") || true
[ "$PROJ_TOP_REAL" = "$PROJ_REAL" ] || refuse "project '$PROJ_REAL' is not a checkout root"
PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"
PROJ_GIT_DIR=$(git_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_GIT_DIR" ] || refuse "project '$PROJ_REAL' has no resolvable git directory"
if [ "$PROJ_GIT_DIR" = "$PROJ_COMMON" ]; then
  PROJ_PRIMARY=$PROJ_REAL
else
  # <project> is itself a linked worktree: its primary checkout is the parent of
  # the shared common dir in the standard non-bare layout, verified rather than
  # assumed by requiring that candidate's own git dir to be the common dir.
  PROJ_PRIMARY=$(real_dir "$(dirname -- "$PROJ_COMMON")") || true
  primary_git_dir=
  [ -z "$PROJ_PRIMARY" ] || primary_git_dir=$(git_dir_of "$PROJ_PRIMARY") || true
  [ -n "$primary_git_dir" ] && [ "$primary_git_dir" = "$PROJ_COMMON" ] \
    || refuse "project '$PROJ_REAL' is a linked worktree whose primary checkout could not be resolved"
fi
[ "$PROJ_PRIMARY" != "$HOME_REAL" ] || refuse "the primary checkout '$PROJ_PRIMARY' is the home directory"

case "$HARNESS" in
  grok)
    STORE_ROOT=${GROK_HOME:-$HOME_REAL/.grok}
    STORE_NAME=trusted_folders.toml
    KEY=$PROJ_PRIMARY
    ;;
esac
case "$STORE_ROOT" in
  /*) ;;
  *) refuse "the $HARNESS home '$STORE_ROOT' is not an absolute path" ;;
esac

# Every interpreter call runs in isolated mode (-I): the helper runs from the
# worker's checkout, and a repository-local tomllib.py must never be imported.
PYTHON=
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -I -c 'import tomllib' >/dev/null 2>&1; then
    PYTHON=$candidate
    break
  fi
done
[ -n "$PYTHON" ] || refuse "python 3.11 or newer (for tomllib) is required to read the trust store and was not found on PATH"

if [ ! -e "$STORE_ROOT" ]; then
  (umask 077 && mkdir -p -- "$STORE_ROOT") 2>/dev/null || true
fi
STORE_DIR_REAL=$(real_dir "$STORE_ROOT") || true
[ -n "$STORE_DIR_REAL" ] || refuse "$HARNESS home '$STORE_ROOT' does not exist and could not be created"
STORE="$STORE_DIR_REAL/$STORE_NAME"
if [ -L "$STORE" ]; then
  STORE_REAL=$("$PYTHON" -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$STORE" 2>/dev/null) || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write under an exclusive flock on a sibling lock file, so two
# Firstmate homes sharing one user store cannot lose each other's entry; the
# kernel drops the lock when this process exits, so a killed registration never
# strands it. The harness itself does not take that lock and rewrites the store
# when a worker answers a dialog, so the fingerprint is compared again
# immediately before the rename and a store that moved is retried, then refused,
# rather than clobbered. Error messages name the store and the path only, never
# its contents.
if ! "$PYTHON" -I - "$HARNESS" "$STORE" "$KEY" <<'PY'
import copy, fcntl, hashlib, json, os, secrets, sys, time, tomllib

harness, store, key = sys.argv[1:]
table, field, value = "folders", "trusted", True


def fail(message):
    print(f"error: {store}: {message}", file=sys.stderr)
    sys.exit(1)


def read():
    try:
        with open(store, "rb") as stream:
            return stream.read()
    except FileNotFoundError:
        return None


def fingerprint(raw):
    return hashlib.sha256(raw).hexdigest() if raw is not None else "absent"


def parse(raw):
    try:
        return tomllib.loads(raw.decode("utf-8")) if raw else {}
    except (UnicodeDecodeError, tomllib.TOMLDecodeError):
        fail("is not valid TOML")


def entries(doc):
    found = doc.get(table, {})
    if not isinstance(found, dict):
        fail(f'has a non-table "{table}" value')
    return found


def decision(doc, path):
    entry = entries(doc).get(path)
    if entry is None:
        return None
    if not isinstance(entry, dict):
        fail(f"has a non-table entry for {path}")
    return entry.get(field)


def attempt():
    original = read()
    before = fingerprint(original)
    doc = parse(original)
    recorded = decision(doc, key)
    if recorded == value:
        return "recorded"
    if recorded is not None:
        fail(f"records an explicit trust decline for {key}; not overriding it")
    text = original.decode("utf-8") if original else ""
    if text and not text.endswith("\n"):
        text += "\n"
    if text:
        text += "\n"
    text += f"[{table}.{json.dumps(key, ensure_ascii=False)}]\n"
    text += f"trusted = true\ndecided_at = {int(time.time())}\n"
    candidate = parse(text.encode("utf-8"))
    expected = copy.deepcopy(doc)
    expected.setdefault(table, {})[key] = {
        field: value,
        "decided_at": candidate.get(table, {}).get(key, {}).get("decided_at"),
    }
    if candidate != expected:
        fail("cannot take an appended trust table without changing its existing entries")
    mode = os.stat(store).st_mode & 0o777 if original is not None else 0o600
    tmp = os.path.join(os.path.dirname(store), f".{os.path.basename(store)}.fm-trust.{os.getpid()}.{secrets.token_hex(8)}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    renamed = False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, mode)
        if fingerprint(read()) != before:
            return "moved"
        os.replace(tmp, store)
        renamed = True
    finally:
        if not renamed:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
    return "recorded" if decision(parse(read()), key) == value else "dropped"


lock_path = f"{store}.fm-lock"
lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    for attempt_number in range(3):
        result = attempt()
        if result == "recorded":
            sys.exit(0)
        if result == "moved" and attempt_number >= 1:
            fail("was modified while trust was being recorded; refusing to overwrite it")
    fail(f"did not retain trust for {key} after 3 attempts")
finally:
    os.close(lock_fd)
PY
then
  refuse "could not record trust for '$KEY' in '$STORE'"
fi

echo "trusted: $KEY"
