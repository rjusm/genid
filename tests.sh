#!/usr/bin/env bash
# tests.sh - automated test suite for genid.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENID="$SCRIPT_DIR/genid.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

section() { echo; echo "=== $1 ==="; }

assert_match() {
  # assert_match "description" "value" "regex"
  local desc=$1 val=$2 re=$3
  if [[ $val =~ $re ]]; then pass "$desc"; else fail "$desc (got: '$val')"; fi
}

assert_eq() {
  local desc=$1 got=$2 want=$3
  if [ "$got" = "$want" ]; then pass "$desc"; else fail "$desc (got: '$got', want: '$want')"; fi
}

# ---------------------------------------------------------------------------
section "basic sanity / help"
# ---------------------------------------------------------------------------

out=$("$GENID" --help 2>&1); rc=$?
assert_eq "help exits 0" "$rc" "0"
if [[ "$out" == *"USAGE:"* ]]; then pass "help contains USAGE"; else fail "help contains USAGE"; fi
if [[ "$out" == *"-m, --mode"* ]]; then pass "help documents short+long flags"; else fail "help documents short+long flags"; fi
if [[ "$out" == *"hex"* && "$out" == *"base64"* && "$out" == *"token"* ]]; then pass "help documents hex/base64/token commands"; else fail "help documents hex/base64/token commands"; fi
if [[ "$out" == *"v7"* ]]; then pass "help documents uuid v7"; else fail "help documents uuid v7"; fi
if [[ "$out" == *"ulid"* ]]; then pass "help documents ulid command"; else fail "help documents ulid command"; fi
if [[ "$out" == *"inspect"* ]]; then pass "help documents inspect command"; else fail "help documents inspect command"; fi
if [[ "$out" == *"passphrase"* ]]; then pass "help documents passphrase mode"; else fail "help documents passphrase mode"; fi
if [[ "$out" == *"--null"* && "$out" == *"--env"* ]]; then pass "help documents --null/--env"; else fail "help documents --null/--env"; fi

"$GENID" >/dev/null 2>&1; rc=$?
assert_eq "no-args exits 1" "$rc" "1"

"$GENID" bogus >/dev/null 2>&1; rc=$?
assert_eq "unknown command exits 1" "$rc" "1"

# ---------------------------------------------------------------------------
section "username"
# ---------------------------------------------------------------------------

u=$("$GENID" username -l 14 2>/dev/null)
assert_match "random username length 14, alnum only" "$u" '^[A-Za-z0-9]{14}$'

u=$("$GENID" username --mode words --sep _ 2>/dev/null)
assert_match "words-mode username format adj_noun_NN" "$u" '^[a-z]+_[a-z]+_[0-9]{2}$'

n=$("$GENID" username -c 5 2>/dev/null | wc -l | tr -d ' ')
assert_eq "username --count 5 produces 5 lines" "$n" "5"

# default length is 10
u=$("$GENID" username 2>/dev/null)
assert_match "default username length is 10" "$u" '^[A-Za-z0-9]{10}$'

"$GENID" username -m bogus >/dev/null 2>&1
assert_eq "invalid --mode exits 1" "$?" "1"

# ---------------------------------------------------------------------------
section "password"
# ---------------------------------------------------------------------------

p=$("$GENID" password 2>/dev/null)
assert_match "default (medium) password length 16" "$p" '^.{16}$'

p=$("$GENID" password -s low 2>/dev/null)
assert_match "low strength length 12" "$p" '^.{12}$'
assert_match "low strength has no symbols" "$p" '^[A-Za-z0-9]+$'

p=$("$GENID" password -s high 2>/dev/null)
assert_match "high strength length 20" "$p" '^.{20}$'

p=$("$GENID" password -s paranoid 2>/dev/null)
assert_match "paranoid strength length 32" "$p" '^.{32}$'

p=$("$GENID" password -s medium -S 2>/dev/null)
assert_match "--no-symbols excludes symbols" "$p" '^[A-Za-z0-9]+$'

p=$("$GENID" password -s medium -A 2>/dev/null)
if [[ "$p" != *[loIO01]* ]]; then pass "--no-ambiguous excludes l,o,I,O,0,1"; else fail "--no-ambiguous excludes l,o,I,O,0,1 (got: $p)"; fi

p=$("$GENID" password -l 24 2>/dev/null)
assert_match "custom --length overrides preset" "$p" '^.{24}$'

"$GENID" password -l 2 >/dev/null 2>&1; rc=$?
assert_eq "password length shorter than class count errors" "$rc" "1"

"$GENID" password -s bogus >/dev/null 2>&1
assert_eq "invalid --strength exits 1" "$?" "1"

# entropy line goes to stderr, not stdout
out=$("$GENID" password 2>/dev/null)
if [[ "$out" != *"entropy"* ]]; then pass "entropy note not mixed into stdout"; else fail "entropy note not mixed into stdout"; fi
errout=$("$GENID" password 2>&1 >/dev/null)
if [[ "$errout" == *"entropy"* ]]; then pass "entropy note present on stderr"; else fail "entropy note present on stderr"; fi
if [[ "$errout" == *"estimated max entropy"* ]]; then pass "entropy is labeled as an estimated max, not exact"; else fail "entropy is labeled as an estimated max, not exact"; fi

n=$("$GENID" password -c 4 2>/dev/null | wc -l | tr -d ' ')
assert_eq "password --count 4 produces 4 lines" "$n" "4"

# uniqueness check across a batch (collision would indicate a serious bug)
uniq_count=$("$GENID" password -s high -c 15 2>/dev/null | sort -u | wc -l | tr -d ' ')
assert_eq "15 generated passwords are all unique" "$uniq_count" "15"

p=$("$GENID" password --charset "abc123" -l 10 2>/dev/null)
assert_match "--charset restricts output to the given characters" "$p" '^[abc123]{10}$'

p=$("$GENID" password --charset "abcloIO01" -l 10 -A 2>/dev/null)
assert_match "--charset combined with --no-ambiguous strips lookalikes from it too" "$p" '^[abc]{10}$'

"$GENID" password --charset "" -l 10 >/dev/null 2>&1
assert_eq "empty --charset errors" "$?" "1"

p=$("$GENID" password --exclude-chars "aeiouAEIOU0123456789" -s high -l 20 2>/dev/null)
if [[ "$p" != *[aeiouAEIOU0-9]* ]]; then
  pass "--exclude-chars removes the given characters from every class"
else
  fail "--exclude-chars removes the given characters from every class (got: $p)"
fi

# regression: exclude-chars starting with '-' must not be misread as a tr flag
p=$("$GENID" password --exclude-chars "-_" -s high -l 20 2>/dev/null); rc=$?
assert_eq "--exclude-chars starting with '-' doesn't crash (tr flag confusion)" "$rc" "0"
if [[ "$p" != *[-_]* ]]; then pass "--exclude-chars '-_' actually excludes - and _"; else fail "--exclude-chars '-_' actually excludes - and _ (got: $p)"; fi

"$GENID" password --exclude-chars "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*()-_=+[]{}?" -s high >/dev/null 2>&1
assert_eq "--exclude-chars emptying every class errors" "$?" "1"

# --- passphrase mode ---

p=$("$GENID" password -m passphrase 2>/dev/null)
assert_match "default passphrase is 5 lowercase words joined by -" "$p" '^[a-z]+(-[a-z]+){4}$'

p=$("$GENID" password -m passphrase -w 3 -p _ 2>/dev/null)
assert_match "passphrase --words 3 --phrase-sep _" "$p" '^[a-z]+(_[a-z]+){2}$'

"$GENID" password -m passphrase -w 1 >/dev/null 2>&1
assert_eq "passphrase --words 1 errors (need at least 2)" "$?" "1"

"$GENID" password -m bogus >/dev/null 2>&1
assert_eq "invalid password --mode errors" "$?" "1"

errout=$("$GENID" password -m passphrase 2>&1 >/dev/null)
if [[ "$errout" == *"wordlist="* && "$errout" == *"bits entropy"* ]]; then
  pass "passphrase prints a wordlist-based entropy estimate"
else
  fail "passphrase prints a wordlist-based entropy estimate (got: $errout)"
fi

n=$("$GENID" password -m passphrase -c 4 2>/dev/null | wc -l | tr -d ' ')
assert_eq "passphrase --count 4 produces 4 lines" "$n" "4"

"$GENID" password --charset "loIO01" -l 10 -A >/dev/null 2>&1
assert_eq "--charset fully stripped by --no-ambiguous errors instead of silently breaking" "$?" "1"

# ---------------------------------------------------------------------------
section "uuid"
# ---------------------------------------------------------------------------

u=$("$GENID" uuid 2>/dev/null)
assert_match "uuid v4 default matches RFC4122 shape" "$u" '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

u=$("$GENID" uuid -v 7 2>/dev/null)
assert_match "uuid v7 matches RFC9562 shape" "$u" '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

n=$("$GENID" uuid -c 6 2>/dev/null | wc -l | tr -d ' ')
assert_eq "uuid --count 6 produces 6 lines" "$n" "6"

uniq_count=$("$GENID" uuid -c 15 2>/dev/null | sort -u | wc -l | tr -d ' ')
assert_eq "15 generated uuids are all unique" "$uniq_count" "15"

uniq_count=$("$GENID" uuid -v 7 -c 15 2>/dev/null | sort -u | wc -l | tr -d ' ')
assert_eq "15 generated uuid v7s are all unique" "$uniq_count" "15"

one_ts=$("$GENID" uuid -v 7 2>/dev/null | cut -c1-8)
assert_match "uuid v7 leading timestamp field is 8 hex digits" "$one_ts" '^[0-9a-f]{8}$'

"$GENID" uuid -v 1 >/dev/null 2>&1
assert_eq "uuid v1 (removed in favor of v7) exits 1" "$?" "1"

"$GENID" uuid -v 5 >/dev/null 2>&1
assert_eq "unsupported uuid version (5) exits 1" "$?" "1"

"$GENID" uuid -v 3 >/dev/null 2>&1
assert_eq "unsupported uuid version (3) exits 1" "$?" "1"

# ---------------------------------------------------------------------------
section "ulid"
# ---------------------------------------------------------------------------

u=$("$GENID" ulid 2>/dev/null)
assert_match "ulid is 26 Crockford-base32 chars" "$u" '^[0-9A-HJKMNP-TV-Z]{26}$'

n=$("$GENID" ulid -c 6 2>/dev/null | wc -l | tr -d ' ')
assert_eq "ulid --count 6 produces 6 lines" "$n" "6"

uniq_count=$("$GENID" ulid -c 15 2>/dev/null | sort -u | wc -l | tr -d ' ')
assert_eq "15 generated ulids are all unique" "$uniq_count" "15"

"$GENID" ulid --foo >/dev/null 2>&1
assert_eq "ulid --foo unknown option exits 1" "$?" "1"

# ---------------------------------------------------------------------------
section "inspect"
# ---------------------------------------------------------------------------

# NOTE: deliberately not re-parsing the printed date string back to an
# epoch here (e.g. via `date -d`) -- that's GNU-only syntax and would fail
# this same test on macOS CI (BSD date needs `-j -f`/`-r` instead). A
# same-year check is portable everywhere and still catches gross decoding
# bugs (wrong byte order, wrong scale, etc. would land far outside it).
this_year=$(date -u +%Y)
u7=$("$GENID" uuid -v 7 2>/dev/null)
out=$("$GENID" inspect "$u7" 2>/dev/null); rc=$?
assert_eq "inspect on a uuid v7 exits 0" "$rc" "0"
if [[ "$out" == *"Format: UUID"* && "$out" == *"Version: 7"* ]]; then
  pass "inspect identifies uuid v7 format/version"
else
  fail "inspect identifies uuid v7 format/version (got: $out)"
fi
if [[ "$out" == *"Timestamp: ${this_year}-"* ]]; then
  pass "inspect's decoded uuid v7 timestamp falls in the current year"
else
  fail "inspect's decoded uuid v7 timestamp falls in the current year (got: $out)"
fi

u4=$("$GENID" uuid 2>/dev/null)
out=$("$GENID" inspect "$u4" 2>/dev/null)
if [[ "$out" == *"Version: 4"* && "$out" == *"not embedded"* ]]; then
  pass "inspect reports no timestamp for uuid v4"
else
  fail "inspect reports no timestamp for uuid v4 (got: $out)"
fi

ulid_val=$("$GENID" ulid 2>/dev/null)
out=$("$GENID" inspect "$ulid_val" 2>/dev/null); rc=$?
assert_eq "inspect on a ulid exits 0" "$rc" "0"
if [[ "$out" == *"Format: ULID"* ]]; then pass "inspect identifies ulid format"; else fail "inspect identifies ulid format (got: $out)"; fi

out=$("$GENID" inspect "$(printf '%s' "$ulid_val" | tr '[:upper:]' '[:lower:]')" 2>/dev/null)
if [[ "$out" == *"Format: ULID"* ]]; then pass "inspect accepts lowercase ulid"; else fail "inspect accepts lowercase ulid (got: $out)"; fi

"$GENID" inspect "not-a-real-id" >/dev/null 2>&1
assert_eq "inspect on garbage input exits 1" "$?" "1"

"$GENID" inspect >/dev/null 2>&1
assert_eq "inspect with no argument exits 1" "$?" "1"

# ---------------------------------------------------------------------------
section "output modes (--null / --env)"
# ---------------------------------------------------------------------------

null_count=$("$GENID" token -c 3 -0 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ')
assert_eq "token --null separates --count 3 output with 3 NUL bytes" "$null_count" "3"

nl_count=$("$GENID" token -c 3 -0 2>/dev/null | tr -cd '\n' | wc -c | tr -d ' ')
assert_eq "token --null output has no newlines" "$nl_count" "0"

out=$("$GENID" token -E APP_KEY 2>/dev/null)
assert_match "--env with count 1 prints NAME=value" "$out" '^APP_KEY=[A-Za-z0-9_-]{32}$'

out=$("$GENID" hex -b 4 -E SALT -c 2 2>/dev/null)
line_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
assert_eq "--env with count 2 produces 2 lines" "$line_count" "2"
if printf '%s\n' "$out" | grep -qE '^SALT_1=[0-9a-f]{8}$' && printf '%s\n' "$out" | grep -qE '^SALT_2=[0-9a-f]{8}$'; then
  pass "--env with count > 1 numbers the names SALT_1/SALT_2"
else
  fail "--env with count > 1 numbers the names SALT_1/SALT_2 (got: $out)"
fi

# ---------------------------------------------------------------------------
section "hex"
# ---------------------------------------------------------------------------

h=$("$GENID" hex -b 16 2>/dev/null)
assert_match "hex -b 16 produces 32 hex chars" "$h" '^[0-9a-f]{32}$'

h=$("$GENID" hex -b 4 2>/dev/null)
assert_match "hex -b 4 produces 8 hex chars" "$h" '^[0-9a-f]{8}$'

"$GENID" hex >/dev/null 2>&1
assert_eq "hex with no --bytes errors" "$?" "1"

"$GENID" hex -b 0 >/dev/null 2>&1
assert_eq "hex -b 0 errors" "$?" "1"

"$GENID" hex -b abc >/dev/null 2>&1
assert_eq "hex -b abc (non-numeric) errors" "$?" "1"

n=$("$GENID" hex -b 8 -c 5 2>/dev/null | wc -l | tr -d ' ')
assert_eq "hex --count 5 produces 5 lines" "$n" "5"

uniq_count=$("$GENID" hex -b 16 -c 10 2>/dev/null | sort -u | wc -l | tr -d ' ')
assert_eq "10 generated hex strings are all unique" "$uniq_count" "10"

# ---------------------------------------------------------------------------
section "base64"
# ---------------------------------------------------------------------------

b=$("$GENID" base64 -b 24 2>/dev/null)
# 24 raw bytes -> exactly 32 base64 chars, no padding needed (24 % 3 == 0)
assert_match "base64 -b 24 produces 32-char base64 (no padding)" "$b" '^[A-Za-z0-9+/]{32}$'

b=$("$GENID" base64 -b 16 2>/dev/null)
# 16 bytes -> 24 base64 chars incl 2 padding '=' (16 % 3 == 1)
assert_match "base64 -b 16 produces well-formed base64 with padding" "$b" '^[A-Za-z0-9+/]{22}==$'

"$GENID" base64 >/dev/null 2>&1
assert_eq "base64 with no --bytes errors" "$?" "1"

n=$("$GENID" base64 -b 8 -c 4 2>/dev/null | wc -l | tr -d ' ')
assert_eq "base64 --count 4 produces 4 lines" "$n" "4"

uniq_count=$("$GENID" base64 -b 16 -c 10 2>/dev/null | sort -u | wc -l | tr -d ' ')
assert_eq "10 generated base64 strings are all unique" "$uniq_count" "10"

# ---------------------------------------------------------------------------
section "token"
# ---------------------------------------------------------------------------

t=$("$GENID" token 2>/dev/null)
assert_match "default token length is 32, url-safe charset" "$t" '^[A-Za-z0-9_-]{32}$'

t=$("$GENID" token -l 64 2>/dev/null)
assert_match "custom --length 64 token" "$t" '^[A-Za-z0-9_-]{64}$'

"$GENID" token -l 0 >/dev/null 2>&1
assert_eq "token -l 0 errors" "$?" "1"

n=$("$GENID" token -c 5 2>/dev/null | wc -l | tr -d ' ')
assert_eq "token --count 5 produces 5 lines" "$n" "5"

t=$("$GENID" token --charset "xyz" -l 12 2>/dev/null)
assert_match "token --charset restricts output to the given characters" "$t" '^[xyz]{12}$'

"$GENID" token --charset "" -l 12 >/dev/null 2>&1
assert_eq "token empty --charset errors" "$?" "1"

t=$("$GENID" token --exclude-chars "-_" -l 20 2>/dev/null); rc=$?
assert_eq "token --exclude-chars starting with '-' doesn't crash" "$rc" "0"
assert_match "token --exclude-chars '-_' actually excludes - and _" "$t" '^[A-Za-z0-9]{20}$'

"$GENID" token --charset "ab" --exclude-chars "ab" >/dev/null 2>&1
assert_eq "token --exclude-chars emptying the whole charset errors" "$?" "1"

uniq_count=$("$GENID" token -c 10 2>/dev/null | sort -u | wc -l | tr -d ' ')
assert_eq "10 generated tokens are all unique" "$uniq_count" "10"

# --- hex -l (length in hex chars, alternate unit to --bytes) ---

h=$("$GENID" hex -l 10 2>/dev/null)
assert_match "hex -l 10 produces exactly 10 hex chars" "$h" '^[0-9a-f]{10}$'

h=$("$GENID" hex -l 5 2>/dev/null)
assert_match "hex -l 5 (odd length) produces exactly 5 hex chars" "$h" '^[0-9a-f]{5}$'

"$GENID" hex -b 4 -l 10 >/dev/null 2>&1
assert_eq "hex -b and -l together errors (mutually exclusive)" "$?" "1"

"$GENID" hex >/dev/null 2>&1
assert_eq "hex with neither --bytes nor --length errors" "$?" "1"

# ---------------------------------------------------------------------------
section "input validation (edge cases from review)"
# ---------------------------------------------------------------------------

errout=$("$GENID" password --length 2>&1); rc=$?
assert_eq "password --length with no value exits 1" "$rc" "1"
if [[ "$errout" == "Error: option '--length' requires a value"* ]]; then pass "missing-value error is clean, not an unbound-variable crash"; else fail "missing-value error is clean (got: $errout)"; fi

"$GENID" password --length abc >/dev/null 2>&1
assert_eq "password --length abc (non-numeric) exits 1" "$?" "1"

"$GENID" password --length 0 >/dev/null 2>&1
assert_eq "password --length 0 exits 1" "$?" "1"

"$GENID" password --length -1 >/dev/null 2>&1
assert_eq "password --length -1 exits 1" "$?" "1"

"$GENID" username --count abc >/dev/null 2>&1
assert_eq "username --count abc (non-numeric) exits 1" "$?" "1"

"$GENID" username --count 0 >/dev/null 2>&1
assert_eq "username --count 0 exits 1" "$?" "1"

"$GENID" username --count -3 >/dev/null 2>&1
assert_eq "username --count -3 exits 1" "$?" "1"

"$GENID" username --length 0 >/dev/null 2>&1
assert_eq "username --length 0 exits 1" "$?" "1"

"$GENID" uuid --count 0 >/dev/null 2>&1
assert_eq "uuid --count 0 exits 1" "$?" "1"

"$GENID" uuid --count abc >/dev/null 2>&1
assert_eq "uuid --count abc exits 1" "$?" "1"

# DoS regression guard: a 64-bit-safe but absurdly large --length used to
# hang forever (script tried to build a string/array of that size). Must
# now fail fast via the MAX_REASONABLE bound instead of hanging.
t0=$(date +%s.%N)
"$GENID" password --length 999999999999999999 >/dev/null 2>&1
rc=$?
t1=$(date +%s.%N)
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')
fast=$(awk -v e="$elapsed" 'BEGIN{print (e<2.0)?1:0}')
assert_eq "huge --length (64-bit-safe) exits 1 instead of hanging" "$rc" "1"
if [ "$fast" -eq 1 ]; then pass "huge --length fails fast (took ${elapsed}s), not a hang"; else fail "huge --length fails fast (took ${elapsed}s) -- possible hang regression"; fi

"$GENID" username --length 99999999999999999999 >/dev/null 2>&1
assert_eq "--length beyond 64-bit range exits 1 cleanly" "$?" "1"

errout=$("$GENID" username --length 99999999999999999999 2>&1)
if [[ "$errout" != *"integer expression expected"* ]]; then pass "no raw bash arithmetic error leaks for oversized --length"; else fail "raw bash error leaked for oversized --length"; fi

# --quiet suppresses the entropy line on stderr
errout=$("$GENID" password -q 2>&1 >/dev/null)
if [ -z "$errout" ]; then pass "-q/--quiet suppresses entropy output"; else fail "-q/--quiet suppresses entropy output (got: $errout)"; fi

# empty separator should be accepted (valid use case, not an error)
u=$("$GENID" username --mode words --sep "" 2>/dev/null)
assert_match "empty --sep is accepted and just concatenates" "$u" '^[a-z]+[a-z]+[0-9]{2}$'

# unknown option still errors cleanly for every subcommand
"$GENID" password --foo >/dev/null 2>&1
assert_eq "password --foo unknown option exits 1" "$?" "1"

"$GENID" uuid --foo >/dev/null 2>&1
assert_eq "uuid --foo unknown option exits 1" "$?" "1"

# ---------------------------------------------------------------------------
section "randomness sanity (statistical, not cryptographic proof)"
# ---------------------------------------------------------------------------

# Two consecutive runs of the same command should not be identical
a=$("$GENID" password -s high 2>/dev/null)
b=$("$GENID" password -s high 2>/dev/null)
if [ "$a" != "$b" ]; then pass "two password invocations differ"; else fail "two password invocations differ"; fi

a=$("$GENID" uuid 2>/dev/null)
b=$("$GENID" uuid 2>/dev/null)
if [ "$a" != "$b" ]; then pass "two uuid invocations differ"; else fail "two uuid invocations differ"; fi

# rough distribution check: large sample of random username chars, no char
# should dominate (would indicate a broken rand_index / modulo bias)
sample=$("$GENID" username -m random -l 1500 2>/dev/null)
max_count=$(echo -n "$sample" | fold -w1 | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
# expected ~24 per char (1500/62); flag only if wildly skewed (>4x expected)
if [ "$max_count" -lt 100 ]; then pass "char distribution not wildly skewed (max=$max_count, expected~24)"; else fail "char distribution skewed (max=$max_count, expected~24)"; fi

# ---------------------------------------------------------------------------
section "fallback path (no openssl on PATH)"
# ---------------------------------------------------------------------------

# Skipped on Windows/MSYS: this test isolates PATH down to a scratch dir
# (env -i PATH="$FAKEBIN") to hide openssl, but MSYS's bash.exe needs
# msys-2.0.dll discoverable via PATH to even start -- so a stripped-down
# PATH breaks bash itself here ("error while loading shared libraries"),
# independent of genid.sh. Linux/macOS don't resolve shared libs via PATH,
# so the same fallback code path (openssl-less -> /dev/urandom) is still
# fully exercised there.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  SKIP: fallback-path tests (bash.exe needs PATH to find its own DLL on Windows/MSYS)"
    ;;
  *)
    FAKEBIN=$(mktemp -d)
    for b in bash od tr date awk basename sort uniq head wc grep fold cat cut base64; do
      p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$FAKEBIN/$b"
    done

    u=$(env -i PATH="$FAKEBIN" HOME="$HOME" "$FAKEBIN/bash" "$GENID" username -l 10 2>/dev/null)
    assert_match "fallback: username still well-formed" "$u" '^[A-Za-z0-9]{10}$'

    p=$(env -i PATH="$FAKEBIN" HOME="$HOME" "$FAKEBIN/bash" "$GENID" password -s high 2>/dev/null)
    assert_match "fallback: password still well-formed" "$p" '^.{20}$'

    uid=$(env -i PATH="$FAKEBIN" HOME="$HOME" "$FAKEBIN/bash" "$GENID" uuid 2>/dev/null)
    assert_match "fallback: uuid v4 still well-formed" "$uid" '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

    uid7=$(env -i PATH="$FAKEBIN" HOME="$HOME" "$FAKEBIN/bash" "$GENID" uuid -v 7 2>/dev/null)
    assert_match "fallback: uuid v7 still well-formed" "$uid7" '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

    hx=$(env -i PATH="$FAKEBIN" HOME="$HOME" "$FAKEBIN/bash" "$GENID" hex -b 12 2>/dev/null)
    assert_match "fallback: hex still well-formed" "$hx" '^[0-9a-f]{24}$'

    b64=$(env -i PATH="$FAKEBIN" HOME="$HOME" "$FAKEBIN/bash" "$GENID" base64 -b 24 2>/dev/null)
    assert_match "fallback: base64 still well-formed" "$b64" '^[A-Za-z0-9+/]{32}$'

    tok=$(env -i PATH="$FAKEBIN" HOME="$HOME" "$FAKEBIN/bash" "$GENID" token -l 20 2>/dev/null)
    assert_match "fallback: token still well-formed" "$tok" '^[A-Za-z0-9_-]{20}$'

    rm -rf "$FAKEBIN"
    ;;
esac

# ---------------------------------------------------------------------------
section "performance regression guard (loose bound, not a benchmark)"
# ---------------------------------------------------------------------------

t0=$(date +%s.%N)
"$GENID" uuid -c 100 >/dev/null 2>&1
t1=$(date +%s.%N)
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')
under_limit=$(awk -v e="$elapsed" 'BEGIN{print (e<3.0)?1:0}')
if [ "$under_limit" -eq 1 ]; then
  pass "uuid --count 100 completes in <3s (took ${elapsed}s) -- catches subshell-per-byte regressions"
else
  fail "uuid --count 100 completes in <3s (took ${elapsed}s)"
fi

# ---------------------------------------------------------------------------
section "results"
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
