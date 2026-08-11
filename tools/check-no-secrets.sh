#!/bin/sh
# Refuse to publish material that must stay in the lab.
#
# WHY THIS EXISTS: the Dell BIOS password derivation was scrubbed from DellCleaner.ps1 before
# the first publish, then silently REINTRODUCED weeks later when the live copy of that file was
# pasted over the scrubbed one. It sat in a public repo until someone happened to grep for it.
# A scrub that is only done once is a scrub that gets undone, so it is enforced here instead.
#
# Run manually, or install as a hook:  ln -sf ../../tools/check-no-secrets.sh .git/hooks/pre-commit
set -e
cd "$(git rev-parse --show-toplevel)"

# Patterns that must never appear in a tracked file. Keep these narrow enough not to fire on
# ordinary text, and specific enough to catch the real thing.
PATTERNS='Convert-sha512
DellExpressServiceCode
Get-DellExpressServiceCode
valsetuppwd=\$
--setuppwd=\$'

FAIL=0
for p in $PATTERNS; do
    # -I skips binaries; check the INDEX (what is about to be committed), not the worktree
    if git grep -I -n -e "$p" -- ':!tools/check-no-secrets.sh' 2>/dev/null | grep -q .; then
        echo "BLOCKED: '$p' found in tracked files:" >&2
        git grep -I -n -e "$p" -- ':!tools/check-no-secrets.sh' >&2
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    cat >&2 <<'MSG'

This repo is public. The Dell BIOS password derivation and the Linux BIOS scripts stay in the
lab - see the private notes for where they live. Remove the offending lines and commit again.
MSG
    exit 1
fi
echo "scrub check passed"
