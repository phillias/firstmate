#!/usr/bin/env bash
# Pre-register a grok or codex worker's folder trust for the isolated task
# worktree a ship/scout spawn is about to launch into, so the worker reaches its
# brief instead of parking on a first-run trust dialog firstmate cannot answer.
#
# Usage: fm-worker-trust.sh <grok|codex> <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
# Exit 0 registered (or already registered), 1 refused, 2 usage, 3 no python
# 3.11+ to read the TOML store with: nothing was inspected or written, which
# bin/fm-spawn.sh reports as a warning rather than a reason to stop the spawn.
#
# WHY THIS EXISTS. Every task worktree is a path the harness has never seen, and
# the operator can pre-register only directories they open by hand. Both
# harnesses keep the decision in a TOML store the launching user owns and honour
# an entry written ahead of launch (verified live under a throwaway home,
# docs/verification/worker-trust.md):
#   grok   ${GROK_HOME:-$HOME/.grok}/trusted_folders.toml, a [folders."<path>"]
#          table with trusted = true. grok keys the decision on the resolved git
#          root, which for a linked worktree is the PRIMARY CHECKOUT: an entry
#          for the worktree path alone is ignored, so the primary checkout is
#          what this records - exactly what answering the dialog writes.
#   codex  ${CODEX_HOME:-$HOME/.codex}/config.toml, a [projects."<path>"] table
#          with trust_level = "trusted". codex honours an entry for the worktree
#          itself, so only that narrowest path is recorded.
# Neither entry is consent the operator did not give elsewhere: an existing
# entry that records a decline (grok trusted other than true, codex trust_level
# other than "trusted" on the worktree or its primary checkout) is refused,
# because a worktree entry would silently override it.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-claude-trust.sh and
# bin/fm-agy-trust.sh: <worktree> must be a LINKED git worktree - its own git
# dir, sharing <project>'s common dir - whose top level is exactly the resolved
# argument, and <project> must be the primary checkout of that repository. A
# primary checkout, a worktree of an unrelated repo, a subdirectory of a
# worktree, a plain directory, and a home directory are each refused with a
# non-zero exit, never a warning and never a silent skip. Only the launching
# user's own store is written, it must be a regular file this uid owns, the new
# table is appended so every existing byte is preserved, the result must parse
# to the original document plus that one entry, and the replacement is atomic.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-worker-trust.sh <grok|codex> <worktree> <project>" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
HARNESS=$1
WT_ARG=$2
PROJ_ARG=$3
case "$HARNESS" in
  grok | codex) ;;
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
PROJ_GIT_DIR=$(git_dir_of "$PROJ_REAL") || true
PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$PROJ_GIT_DIR" = "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not a primary checkout"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

case "$HARNESS" in
  grok)
    STORE_ROOT=${GROK_HOME:-$HOME_REAL/.grok}
    STORE_NAME=trusted_folders.toml
    KEY=$PROJ_REAL
    ;;
  codex)
    STORE_ROOT=${CODEX_HOME:-$HOME_REAL/.codex}
    STORE_NAME=config.toml
    KEY=$WT_REAL
    ;;
esac
case "$STORE_ROOT" in
  /*) ;;
  *) refuse "the $HARNESS home '$STORE_ROOT' is not an absolute path" ;;
esac

PYTHON=
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
    PYTHON=$candidate
    break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "error: cannot pre-register $HARNESS trust: python 3.11 or newer (for tomllib) is required to read the trust store and was not found on PATH" >&2
  exit 3
fi

if [ ! -e "$STORE_ROOT" ]; then
  (umask 077 && mkdir -p -- "$STORE_ROOT") 2>/dev/null || true
fi
STORE_DIR_REAL=$(real_dir "$STORE_ROOT") || true
[ -n "$STORE_DIR_REAL" ] || refuse "$HARNESS home '$STORE_ROOT' does not exist and could not be created"
STORE="$STORE_DIR_REAL/$STORE_NAME"
if [ -L "$STORE" ]; then
  STORE_REAL=$("$PYTHON" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$STORE" 2>/dev/null) || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write with a fingerprint check before the rename and a readback
# after it: the harness itself rewrites this store when a worker answers a
# dialog, so a store that moved under us is retried and then refused rather
# than clobbered. Error messages name the store and the path only, never its
# contents.
if ! "$PYTHON" -I - "$HARNESS" "$STORE" "$KEY" "$PROJ_REAL" <<'PY'
import copy, hashlib, json, os, secrets, sys, time, tomllib

harness, store, key, project = sys.argv[1:]
table, field, value = ("folders", "trusted", True) if harness == "grok" else ("projects", "trust_level", "trusted")


def fail(message):
    print(f"error: {store}: {message}", file=sys.stderr)
    sys.exit(1)


def read():
    try:
        with open(store, "rb") as stream:
            return stream.read()
    except FileNotFoundError:
        return None


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


def check_declines(doc):
    paths = [key] if harness == "grok" else [key, project]
    for path in paths:
        recorded = decision(doc, path)
        if recorded is not None and recorded != value:
            fail(f"records an explicit trust decline for {path}; not overriding it")


def attempt():
    original = read()
    before = hashlib.sha256(original).hexdigest() if original is not None else "absent"
    doc = parse(original)
    check_declines(doc)
    if decision(doc, key) == value:
        return "recorded"
    text = original.decode("utf-8") if original else ""
    if text and not text.endswith("\n"):
        text += "\n"
    if text:
        text += "\n"
    text += f"[{table}.{json.dumps(key, ensure_ascii=False)}]\n"
    if harness == "grok":
        text += f"trusted = true\ndecided_at = {int(time.time())}\n"
    else:
        text += 'trust_level = "trusted"\n'
    candidate = parse(text.encode("utf-8"))
    expected = copy.deepcopy(doc)
    expected.setdefault(table, {})[key] = {field: value}
    if harness == "grok":
        expected[table][key]["decided_at"] = candidate.get(table, {}).get(key, {}).get("decided_at")
    if candidate != expected:
        fail("cannot take an appended trust table without changing its existing entries")
    mode = os.stat(store).st_mode & 0o777 if original is not None else 0o600
    tmp = os.path.join(os.path.dirname(store), f".{os.path.basename(store)}.fm-trust.{os.getpid()}.{secrets.token_hex(8)}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    renamed = False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.chmod(tmp, mode)
        current = read()
        if (hashlib.sha256(current).hexdigest() if current is not None else "absent") != before:
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


for attempt_number in range(3):
    result = attempt()
    if result == "recorded":
        sys.exit(0)
    if result == "moved" and attempt_number >= 1:
        fail("was modified while trust was being recorded; refusing to overwrite it")
fail(f"did not retain trust for {key} after 3 attempts")
PY
then
  refuse "could not record trust for '$KEY' in '$STORE'"
fi

echo "trusted: $KEY"
