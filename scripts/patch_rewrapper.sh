#!/usr/bin/env bash
# Patch prebuilts/remoteexecution-client/live/rewrapper so it sends
# working_directory="" instead of working_directory="." to reproxy.
#
# Background: when AOSP builds from the tree root, rewrapper computes
# WorkDir = filepath.Rel(PWD, ExecRoot) = ".". That "." is forwarded to
# reproxy and on into the REAPI Action proto. BuildBuddy (and likely other
# strict REAPI backends) reject it with:
#
#   FailedPrecondition: working_directory "." does not exist in the input tree
#
# Per the REAPI spec, "" and "." both denote the input root, so emitting ""
# is the safe fix. This script forces WorkDir to ("", 0) right after the
# filepath.Rel call inside main.main, before the value is stored into
# main.cOpts.WorkDir.
#
# The patch targets the AOSP-shipped rewrapper at version 0.132.0.1a8ff94
# (md5 493d4d01bdd760cd98bd96b9286bd097). Idempotent: re-running on an
# already-patched binary is a no-op.

set -euo pipefail

REWRAPPER="${REWRAPPER:-prebuilts/remoteexecution-client/live/rewrapper}"

if [[ ! -f "$REWRAPPER" ]]; then
  echo "error: $REWRAPPER not found. Run this from the tree root." >&2
  exit 1
fi

# File offsets and bytes we expect. VAs in comments are for cross-reference
# with `objdump -d`. These come from rewrapper 0.132.0.1a8ff94.

#   VA 0x820ff2 (file 0x420ff2): the 7-byte 'mov 0x4e08e7(%rip),%rdx' that
#   reloads main.cOpts right after 'call filepath.Rel'. We replace it with a
#   5-byte call to a trampoline + 2-byte nop pad.
CALL_OFF=$((0x420ff2))
CALL_ORIG="488b15e7084e00"
CALL_PATCHED="e835070000 9090"; CALL_PATCHED="${CALL_PATCHED// /}"

#   VA 0x82172c (file 0x42172c): 20 bytes of int3 padding between
#   main.main.func2 and main.init. The trampoline (12 bytes) goes here,
#   followed by 8 bytes of int3 to preserve the section size.
TRAMP_OFF=$((0x42172c))
TRAMP_ORIG="cccccccccccccccccccccccccccccccccccccccc"      # 20 bytes int3
# Trampoline body (12 bytes):
#   48 8b 15 ad 01 4e 00   mov 0x4e01ad(%rip),%rdx   # reload main.cOpts
#   31 db                  xor %ebx,%ebx              # clear WorkDir.len
#   31 c0                  xor %eax,%eax              # clear WorkDir.ptr
#   c3                     ret
TRAMP_BODY="488b15ad014e0031db31c0c3"
TRAMP_PATCHED="${TRAMP_BODY}cccccccccccccccc"               # body + 8 int3

read_hex() {
  # read_hex <offset> <length> → lowercase hex of those bytes
  local off=$1 len=$2
  xxd -p -s "$off" -l "$len" "$REWRAPPER" | tr -d '\n'
}

cur_call=$(read_hex "$CALL_OFF" 7)
cur_tramp=$(read_hex "$TRAMP_OFF" 20)

if [[ "$cur_call" == "$CALL_PATCHED" && "$cur_tramp" == "$TRAMP_PATCHED" ]]; then
  echo "$REWRAPPER is already patched. Nothing to do."
  exit 0
fi

if [[ "$cur_call" != "$CALL_ORIG" ]]; then
  echo "error: bytes at file offset 0x$(printf %x "$CALL_OFF") do not match" >&2
  echo "       the expected rewrapper-0.132 sequence." >&2
  echo "       expected: $CALL_ORIG" >&2
  echo "       found:    $cur_call" >&2
  echo "If your rewrapper is a different build, this script will need new offsets." >&2
  exit 2
fi

if [[ "$cur_tramp" != "$TRAMP_ORIG" ]]; then
  echo "error: expected 20 bytes of int3 padding at file offset 0x$(printf %x "$TRAMP_OFF")" >&2
  echo "       but found: $cur_tramp" >&2
  exit 2
fi

# Keep a copy of the original next to the binary. cp -n so we never
# overwrite a real backup with an already-patched binary.
if [[ ! -f "$REWRAPPER.bak.orig" ]]; then
  cp -n "$REWRAPPER" "$REWRAPPER.bak.orig"
  echo "Saved backup: $REWRAPPER.bak.orig"
fi

# Apply both patches with dd. conv=notrunc keeps the rest of the file intact.
write_hex() {
  # write_hex <offset> <hex>
  local off=$1 hex=$2
  printf '%s' "$hex" | xxd -r -p \
    | dd of="$REWRAPPER" bs=1 seek="$off" conv=notrunc status=none
}

write_hex "$TRAMP_OFF" "$TRAMP_PATCHED"
write_hex "$CALL_OFF"  "$CALL_PATCHED"

# Verify the bytes landed.
new_call=$(read_hex "$CALL_OFF" 7)
new_tramp=$(read_hex "$TRAMP_OFF" 20)
if [[ "$new_call" != "$CALL_PATCHED" || "$new_tramp" != "$TRAMP_PATCHED" ]]; then
  echo "error: post-patch verification failed; restore from $REWRAPPER.bak.orig" >&2
  exit 3
fi

echo "Patched $REWRAPPER."
echo "  call site at 0x$(printf %x "$CALL_OFF"):  $CALL_ORIG  →  $CALL_PATCHED"
echo "  trampoline at 0x$(printf %x "$TRAMP_OFF"): (int3 pad)  →  $TRAMP_BODY..."
echo
echo "Smoke test:"
"$REWRAPPER" -version
