#!/bin/bash
# release.sh — build + selftest + install check + optional tag (W16).
#
#   scripts/release.sh            build release, selftest, verify install
#   scripts/release.sh --tag      also create annotated git tag v<version>
#   scripts/release.sh --dry-run  print what each step would run, do nothing
#
# Steps: swift build -c release → binary selftest (`--version`, `prime` on
# this indexed repo) → verify ~/.local/bin/swctx points at the freshly
# built .build/release/swctx (mismatch is reported with instructions —
# the script never repoints it silently) → optional `git tag -a`.
# Every step prints PASS/FAIL; any failure exits non-zero.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1   # repo root
REPO="$(pwd -P)"
BIN="$REPO/.build/release/swctx"
LINK="$HOME/.local/bin/swctx"
MAIN_SWIFT="$REPO/Sources/swctx/main.swift"

TAG=0
DRY=0
for arg in "$@"; do
    case "$arg" in
        --tag) TAG=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

rc_all=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; rc_all=1; }

VERSION="$(sed -n 's/.*version: "\([^"]*\)".*/\1/p' "$MAIN_SWIFT" | head -1)"
if [ -z "$VERSION" ]; then
    echo "release.sh: could not parse version from $MAIN_SWIFT" >&2
    exit 1
fi
echo "release.sh: swctx version $VERSION"

# --- 1. release build ------------------------------------------------------
if [ "$DRY" -eq 1 ]; then
    echo "DRY   build: swift build -c release"
else
    if swift build -c release; then
        pass "build (swift build -c release)"
    else
        fail "build (swift build -c release)"
    fi
fi

# --- 2. binary selftest ----------------------------------------------------
if [ "$DRY" -eq 1 ]; then
    echo "DRY   selftest: $BIN --version && $BIN prime $REPO"
else
    if [ ! -x "$BIN" ]; then
        fail "selftest ($BIN missing or not executable)"
    else
        bin_version="$("$BIN" --version 2>&1)" || bin_version=""
        if [ "$bin_version" = "$VERSION" ]; then
            pass "selftest --version ($bin_version)"
        else
            fail "selftest --version (got '${bin_version:-<no output>}', want $VERSION)"
        fi
        if "$BIN" prime "$REPO" >/dev/null 2>&1; then
            pass "selftest prime ($REPO)"
        else
            fail "selftest prime ($REPO rc=$?)"
        fi
    fi
fi

# --- 3. install symlink ----------------------------------------------------
bin_real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$BIN")"
if [ "$DRY" -eq 1 ]; then
    echo "DRY   install: check $LINK -> $bin_real"
elif [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then
    fail "install ($LINK does not exist)"
    cat <<EOF
      To install:  mkdir -p "$HOME/.local/bin" && ln -sfn "$BIN" "$LINK"
      (release.sh reports only — it never repoints the symlink itself)
EOF
else
    link_real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$LINK")"
    if [ "$link_real" = "$bin_real" ]; then
        pass "install ($LINK -> $(readlink "$LINK" 2>/dev/null || echo "$link_real"))"
    else
        fail "install ($LINK -> $link_real, expected $bin_real)"
        cat <<EOF
      To repoint:  ln -sfn "$BIN" "$LINK"
      (release.sh reports only — it never repoints the symlink itself;
       if this target is intentional, keep it and ignore this failure)
EOF
    fi
fi

# --- 4. optional annotated tag ---------------------------------------------
if [ "$TAG" -eq 1 ]; then
    tag="v$VERSION"
    if [ "$DRY" -eq 1 ]; then
        echo "DRY   tag: git tag -a $tag -m 'swctx $tag'"
    elif git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
        fail "tag ($tag already exists)"
    elif ! git diff --quiet || ! git diff --cached --quiet; then
        fail "tag (working tree dirty — commit before tagging)"
    else
        if git tag -a "$tag" -m "swctx $tag"; then
            pass "tag ($tag — push with: git push origin $tag)"
        else
            fail "tag (git tag -a $tag)"
        fi
    fi
fi

if [ "$rc_all" -eq 0 ]; then
    echo "release.sh: ALL STEPS PASSED"
else
    echo "release.sh: FAILED" >&2
fi
exit "$rc_all"
