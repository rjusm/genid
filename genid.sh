#!/usr/bin/env bash
# genid.sh - portable random data generator: username, password, UUID
# (v4/v7), hex, base64, token. Pure bash + coreutils (od, tr, date, awk,
# base64); openssl used opportunistically for randomness if present, but
# nothing here is a hard dependency. Never uses $RANDOM (weak, seedable
# PRNG) -- randomness comes from /dev/urandom or `openssl rand`, with
# rejection sampling for unbiased charset selection.

set -eu
# No pathname expansion is ever needed in this script (it only builds and
# prints strings), so globbing is disabled defensively -- pure hardening,
# no functional dependency on it.
set -f

err() {
  echo "Error: $*" >&2
  echo >&2
  usage >&2
  exit 1
}

# is_pos_int VALUE: true if VALUE is a positive integer (>=1), no sign, no
# decimals, no leading garbage. Used to validate --length/--count/etc.
is_pos_int() {
  case "$1" in
    ''|*[!0-9]*) return 1;;
  esac
  # Reject unreasonably long digit strings before doing an arithmetic
  # comparison on them: values beyond 64-bit range make `[ -ge ]` itself
  # throw a raw "integer expression expected" bash error instead of a
  # clean one, and even values that DO fit in 64-bit but are this long
  # are already well past MAX_REASONABLE below. 10 digits comfortably
  # covers any legitimate input while ruling both cases out up front.
  if [ "${#1}" -gt 10 ]; then
    return 1
  fi
  [ "$1" -ge 1 ]
}

# Upper bound for any user-supplied length/count/bytes value. Without this,
# e.g. `password --length 999999999999999999` passes is_pos_int fine (it's
# a valid positive integer, well within 64-bit arithmetic) but then the
# script tries to build a string/array of that size and hangs forever --
# a real, reachable denial-of-service via a single flag, not just a
# theoretical concern. 10,000,000 is generous for any legitimate use of
# this tool while making that class of hang unreachable.
MAX_REASONABLE=10000000

require_pos_int() {
  # require_pos_int "flag name" "$value"
  is_pos_int "$2" || err "$1 must be a positive integer (got: '$2')"
  if [ "$2" -gt "$MAX_REASONABLE" ]; then
    err "$1 is too large (got: '$2', max: $MAX_REASONABLE)"
  fi
}

# need_arg FLAG_NAME "$@..." -- call as: need_arg "$1" "$#"  before consuming
# $2 as a value, so a trailing flag with no value gets a clean error instead
# of an "unbound variable" crash under `set -u`.
need_arg() {
  [ "$2" -ge 2 ] || err "option '$1' requires a value"
}

# ---------------------------------------------------------------------------
# Randomness core
#
# rand_byte/rand_hex_byte/rand_index write their result into a global
# variable (_RAND_OUT / _RAND_HEX_OUT) instead of `echo`-ing it. This is
# deliberate: capturing a function's output via $(...) forks a subshell,
# and with these functions called once per character/byte generated, that
# forking dominates runtime by roughly an order of magnitude versus the
# actual entropy source (openssl/od). Don't reintroduce $(...) capture on
# these three functions without re-benchmarking.
# ---------------------------------------------------------------------------

HAVE_OPENSSL=0
if command -v openssl >/dev/null 2>&1; then
  HAVE_OPENSSL=1
fi

# Random byte buffer, stored as a bash array of decimal values (0-255) with
# a cursor, so consuming a byte is O(1) (array index + counter bump) rather
# than re-splitting/rebuilding a string on every call.
_RAND_ARR=()
_RAND_POS=0

_refill_rand_buf() {
  local n=256 hex
  if [ "$HAVE_OPENSSL" -eq 1 ]; then
    hex=$(openssl rand -hex "$n")
  else
    hex=$(od -An -N"$n" -tx1 /dev/urandom | tr -d ' \n')
  fi
  _RAND_ARR=()
  local i=0 len=${#hex}
  while [ "$i" -lt "$len" ]; do
    _RAND_ARR+=( "$((16#${hex:i:2}))" )
    i=$((i + 2))
  done
  _RAND_POS=0
}

# rand_byte: sets _RAND_OUT to one random byte value (0-255). No subshell.
rand_byte() {
  if [ "$_RAND_POS" -ge "${#_RAND_ARR[@]}" ]; then
    _refill_rand_buf
  fi
  _RAND_OUT=${_RAND_ARR[_RAND_POS]}
  _RAND_POS=$((_RAND_POS + 1))
}

# rand_hex_byte: sets _RAND_HEX_OUT to one random byte as two hex digits.
rand_hex_byte() {
  rand_byte
  printf -v _RAND_HEX_OUT '%02x' "$_RAND_OUT"
}

# rand_index MAX: sets _RAND_OUT to a uniformly random integer in [0, MAX).
# Rejection sampling avoids modulo bias. Correct for any MAX up to bash's
# 64-bit arithmetic limits; every call site here passes either a small
# fixed constant or a value already capped by MAX_REASONABLE via
# require_pos_int, so the guard below is defense-in-depth for future
# callers, not something normal use can trigger.
rand_index() {
  local max=$1
  if [ "$max" -le 1 ]; then
    _RAND_OUT=0
    return
  fi
  if [ "$max" -gt 1000000000000 ]; then
    err "internal error: rand_index called with an unreasonably large max ($max)"
  fi

  local bytes_needed=1 range=256
  while [ "$range" -lt "$max" ]; do
    bytes_needed=$((bytes_needed + 1))
    range=$((range * 256))
  done

  local limit=$(( (range / max) * max ))
  local val i
  while :; do
    val=0
    i=0
    while [ "$i" -lt "$bytes_needed" ]; do
      rand_byte
      val=$(( val * 256 + _RAND_OUT ))
      i=$((i + 1))
    done
    if [ "$val" -lt "$limit" ]; then
      _RAND_OUT=$(( val % max ))
      return
    fi
  done
}

# ---------------------------------------------------------------------------
# Wordlists (compact, built-in)
# ---------------------------------------------------------------------------

ADJ=(brave calm dusty eager fuzzy giant happy icy jolly keen lively misty noble odd proud quiet rapid sharp tidy urban vivid witty young zesty amber bold crisp dark east fine)
NOUN=(otter falcon river cloud tiger maple stone ember delta harbor lynx meadow quartz raven summit tundra vale willow zephyr comet dune ridge fern glade heron ivy jade knoll lark)

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

usage() {
cat <<'EOF'
genid.sh - portable random data generator for devs/devops (bash, /dev/urandom, no hard deps)

USAGE:
  genid.sh <command> [options]

COMMANDS:

  username [options]
    Generate a random username.
    -m, --mode random|words   "random" = alnum string, "words" = adjective-noun-number.
                               (default: random)
    -l, --length N            Length for "random" mode. (default: 10)
    -s, --sep STR              Separator for "words" mode. (default: -)
    -c, --count N                 How many to generate. (default: 1)

  password [options]
    Generate a cryptographically random password.
    -s, --strength low|medium|high|paranoid
                               low=12 chars alnum, medium=16 +symbols (default),
                               high=20 full charset, paranoid=32 full charset.
    -l, --length N            Overrides preset length.
    -S, --no-symbols           Exclude symbol characters.
    -A, --no-ambiguous          Exclude lookalikes (l, o, I, O, 0, 1).
    -q, --quiet                 Suppress the entropy estimate on stderr.
    -c, --count N                 How many to generate. (default: 1)
    (Each password prints with an estimated max entropy in bits, to stderr,
    unless -q/--quiet is given.)

  uuid [options]
    Generate an RFC-shaped UUID.
    -v, --version 4|7         v4 = fully random (default). v7 = time-ordered:
                               second-accurate timestamp + random tail --
                               good for sortable IDs / DB primary keys.
                               Ordering is correct between different
                               seconds, undefined within the same second
                               (see NOTES).
    -c, --count N                 How many to generate. (default: 1)

  hex [options]
    Generate random data as a hex string.
    -b, --bytes N              Number of random bytes to generate. (required)
    -c, --count N                 How many to generate. (default: 1)

  base64 [options]
    Generate random data as base64 text.
    -b, --bytes N              Number of random bytes to generate. (required)
    -c, --count N                 How many to generate. (default: 1)

  token [options]
    Generate a URL-safe random token (letters, digits, '-', '_'). Handy
    for API keys, session secrets, one-off identifiers.
    -l, --length N             Token length in characters. (default: 32)
    -c, --count N                 How many to generate. (default: 1)

  -h, --help                  Show this help and exit.

NOTES:
  - Uses openssl for randomness if installed, otherwise falls back to
    /dev/urandom automatically -- no dependency is required either way.
  - $RANDOM is never used (it's a weak, seedable PRNG). All charset
    selection uses rejection sampling to avoid modulo bias.
  - UUID v1/v3/v5 are not supported. v1's real requirements (100ns clock,
    real MAC address) aren't reliably available in stock macOS bash/date;
    v7 covers the same "time-ordered ID" need with a format that's honest
    about the precision it actually has, so it replaces v1 here.
  - UUID v7 timestamp is accurate to the current SECOND (from `date`,
    portable everywhere). The millisecond field within that second is
    random, not the real current millisecond (no portable sub-second
    clock in stock macOS bash/date). So ordering is correct between
    UUIDs from different seconds, but UUIDs generated within the same
    second have no defined order relative to each other.
  - 'base64' subcommand uses the system 'base64' command if present
    (virtually always true on Linux/macOS/WSL), else falls back to
    'openssl rand -base64' if openssl is available.
  - Password "entropy" printed on stderr is an estimated MAXIMUM (the
    entropy of an unconstrained pick from charset^length). The actual
    scheme guarantees >=1 char per active class, which slightly shrinks
    the real keyspace versus this upper-bound figure.
  - Randomness is pulled in bulk (256 bytes per refill) and consumed
    in-process without forking a subshell per character, so --count with
    dozens/hundreds of items is fast (sub-second for uuid/hex/token at
    --count 100). The 'base64' subcommand is the one exception: it pipes
    into the external 'base64' binary, which forks a subshell per item
    and loses the shared byte buffer across --count iterations (see
    in-script comment) -- still correct and secure, just not as fast at
    very large --count.
  - Any --length/--count/--bytes value is capped at 10,000,000. This is
    generous for real use and exists to fail fast on a mistyped huge
    number rather than trying to build something absurdly large.
EOF
}

# ---------------------------------------------------------------------------
# username
# ---------------------------------------------------------------------------

cmd_username() {
  local mode="random" length=10 count=1 sep="-"
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--mode) need_arg "$1" "$#"; mode=$2; shift 2;;
      -l|--length) need_arg "$1" "$#"; length=$2; shift 2;;
      -s|--sep) need_arg "$1" "$#"; sep=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'username': $1";;
    esac
  done

  case "$mode" in
    random|words) ;;
    *) err "invalid --mode '$mode' (expected random|words)";;
  esac
  require_pos_int "--length" "$length"
  require_pos_int "--count" "$count"

  local charset="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local n
  n=0
  while [ "$n" -lt "$count" ]; do
    if [ "$mode" = "words" ]; then
      local a no num
      rand_index ${#ADJ[@]}; a=${ADJ[_RAND_OUT]}
      rand_index ${#NOUN[@]}; no=${NOUN[_RAND_OUT]}
      rand_index 90; num=$(( _RAND_OUT + 10 ))
      echo "${a}${sep}${no}${sep}${num}"
    else
      local out="" i idx
      i=0
      while [ "$i" -lt "$length" ]; do
        rand_index ${#charset}; idx=$_RAND_OUT
        out="${out}${charset:idx:1}"
        i=$((i+1))
      done
      echo "$out"
    fi
    n=$((n+1))
  done
}

# ---------------------------------------------------------------------------
# password
# ---------------------------------------------------------------------------

cmd_password() {
  local strength="medium" length="" count=1 use_symbols=1 use_ambiguous=1 quiet=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--strength) need_arg "$1" "$#"; strength=$2; shift 2;;
      -l|--length) need_arg "$1" "$#"; length=$2; shift 2;;
      -S|--no-symbols) use_symbols=0; shift;;
      -A|--no-ambiguous) use_ambiguous=0; shift;;
      -q|--quiet) quiet=1; shift;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'password': $1";;
    esac
  done

  case "$strength" in
    low) : "${length:=12}"; use_symbols=0;;
    medium) : "${length:=16}";;
    high) : "${length:=20}";;
    paranoid) : "${length:=32}";;
    *) err "invalid --strength '$strength' (expected low|medium|high|paranoid)";;
  esac
  require_pos_int "--length" "$length"
  require_pos_int "--count" "$count"

  local lower="abcdefghijklmnopqrstuvwxyz"
  local upper="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  local digits="0123456789"
  local symbols='!@#$%^&*()-_=+[]{}?'

  if [ "$use_ambiguous" -eq 0 ]; then
    lower=$(echo "$lower" | tr -d 'lo')
    upper=$(echo "$upper" | tr -d 'IO')
    digits=$(echo "$digits" | tr -d '01')
  fi

  local classes=("$lower" "$upper" "$digits")
  if [ "$use_symbols" -eq 1 ]; then
    classes+=("$symbols")
  fi

  local charset="" c
  for c in "${classes[@]}"; do
    charset="${charset}${c}"
  done

  local nclasses=${#classes[@]}
  if [ "$length" -lt "$nclasses" ]; then
    err "length ($length) too short for the selected character classes ($nclasses required)"
  fi

  local n
  n=0
  while [ "$n" -lt "$count" ]; do
    local pass=()
    for c in "${classes[@]}"; do
      rand_index ${#c}
      pass+=("${c:_RAND_OUT:1}")
    done

    local remaining=$(( length - nclasses ))
    local i idx
    i=0
    while [ "$i" -lt "$remaining" ]; do
      rand_index ${#charset}; idx=$_RAND_OUT
      pass+=("${charset:idx:1}")
      i=$((i+1))
    done

    # Fisher-Yates shuffle using rejection-sampled indices
    local j tmp
    i=$(( ${#pass[@]} - 1 ))
    while [ "$i" -gt 0 ]; do
      rand_index $((i+1)); j=$_RAND_OUT
      tmp=${pass[i]}; pass[i]=${pass[j]}; pass[j]=$tmp
      i=$((i-1))
    done

    local out="" p
    for p in "${pass[@]}"; do
      out="${out}${p}"
    done
    echo "$out"
    if [ "$quiet" -eq 0 ]; then
      # NOTE: this is the entropy of an unconstrained uniform pick from
      # charset^length -- an UPPER BOUND, not the exact entropy of this
      # scheme. Guaranteeing >=1 char per class shrinks the real keyspace
      # slightly (excludes combinations missing a required class), so
      # true entropy is a bit lower than this number, especially for
      # short passwords with many required classes.
      awk -v n="${#charset}" -v l="$length" \
        'BEGIN{printf "  (charset=%d, length=%d, ~%.1f bits estimated max entropy)\n", n, l, l*log(n)/log(2)}' >&2
    fi

    n=$((n+1))
  done
}

# ---------------------------------------------------------------------------
# uuid
# ---------------------------------------------------------------------------

uuid_v4() {
  local b=() i
  i=0
  while [ "$i" -lt 16 ]; do
    rand_hex_byte
    b+=("0x$_RAND_HEX_OUT")
    i=$((i+1))
  done
  b[6]=$(( (b[6] & 0x0f) | 0x40 ))
  b[8]=$(( (b[8] & 0x3f) | 0x80 ))
  printf '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n' "${b[@]}"
}

uuid_v7() {
  # RFC 9562 UUIDv7: 48-bit unix_ts_ms, 4-bit version, 12-bit rand_a,
  # 2-bit variant, 62-bit rand_b. The timestamp field is accurate to the
  # current second (from `date +%s`, portable everywhere); the
  # millisecond portion within that second is a RANDOM position, not the
  # actual current millisecond (stock macOS bash/date has no reliable
  # %N to get that). So: correct ordering between UUIDs generated in
  # different seconds, but no defined ordering between UUIDs generated
  # within the same second -- fine for a sortable/unique identifier at
  # second granularity, not for sub-second causal ordering.
  local secs ms
  secs=$(date -u +%s)
  rand_index 1000
  ms=$(( secs * 1000 + _RAND_OUT ))

  local b=() i
  b[0]=$(( (ms >> 40) & 0xff ))
  b[1]=$(( (ms >> 32) & 0xff ))
  b[2]=$(( (ms >> 24) & 0xff ))
  b[3]=$(( (ms >> 16) & 0xff ))
  b[4]=$(( (ms >> 8) & 0xff ))
  b[5]=$(( ms & 0xff ))
  i=6
  while [ "$i" -lt 16 ]; do
    rand_hex_byte
    b[i]="0x$_RAND_HEX_OUT"
    i=$((i+1))
  done
  b[6]=$(( (b[6] & 0x0f) | 0x70 ))
  b[8]=$(( (b[8] & 0x3f) | 0x80 ))
  printf '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n' "${b[@]}"
}

cmd_uuid() {
  local version=4 count=1
  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--version) need_arg "$1" "$#"; version=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'uuid': $1";;
    esac
  done
  require_pos_int "--count" "$count"

  local n
  n=0
  while [ "$n" -lt "$count" ]; do
    case "$version" in
      4) uuid_v4;;
      7) uuid_v7;;
      *) err "unsupported UUID version '$version' (only 4 and 7 are supported)";;
    esac
    n=$((n+1))
  done
}

# ---------------------------------------------------------------------------
# hex
# ---------------------------------------------------------------------------

cmd_hex() {
  local bytes="" count=1
  while [ $# -gt 0 ]; do
    case "$1" in
      -b|--bytes) need_arg "$1" "$#"; bytes=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'hex': $1";;
    esac
  done
  [ -n "$bytes" ] || err "--bytes is required for 'hex'"
  require_pos_int "--bytes" "$bytes"
  require_pos_int "--count" "$count"

  local n i out
  n=0
  while [ "$n" -lt "$count" ]; do
    out=""
    i=0
    while [ "$i" -lt "$bytes" ]; do
      rand_hex_byte
      out="${out}${_RAND_HEX_OUT}"
      i=$((i+1))
    done
    echo "$out"
    n=$((n+1))
  done
}

# ---------------------------------------------------------------------------
# base64
# ---------------------------------------------------------------------------

cmd_base64() {
  local bytes="" count=1
  while [ $# -gt 0 ]; do
    case "$1" in
      -b|--bytes) need_arg "$1" "$#"; bytes=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'base64': $1";;
    esac
  done
  [ -n "$bytes" ] || err "--bytes is required for 'base64'"
  require_pos_int "--bytes" "$bytes"
  require_pos_int "--count" "$count"

  if ! command -v base64 >/dev/null 2>&1 && [ "$HAVE_OPENSSL" -eq 0 ]; then
    err "'base64' subcommand needs either the 'base64' or 'openssl' program on PATH (neither found)"
  fi

  local n i b hexbyte
  n=0
  while [ "$n" -lt "$count" ]; do
    if command -v base64 >/dev/null 2>&1; then
      # NOTE: this inner loop is piped into `base64`, forking a subshell.
      # Any refill of _RAND_ARR inside that subshell is invisible to the
      # parent once the pipe closes, so each --count iteration here tends
      # to trigger its own fresh 256-byte refill instead of reusing the
      # parent's buffer. Not a randomness bug -- every refill still pulls
      # fresh bytes from openssl/urandom -- just slightly wasteful at
      # large --count. Not worth the complexity of a shared pool for a
      # minor efficiency gain.
      i=0
      while [ "$i" -lt "$bytes" ]; do
        rand_hex_byte
        hexbyte=$_RAND_HEX_OUT
        printf '%b' "\\x${hexbyte}"
        i=$((i+1))
      done | base64 | tr -d '\n'
    else
      openssl rand -base64 "$bytes" | tr -d '\n'
    fi
    echo
    n=$((n+1))
  done
}

# ---------------------------------------------------------------------------
# token
# ---------------------------------------------------------------------------

cmd_token() {
  local length=32 count=1
  while [ $# -gt 0 ]; do
    case "$1" in
      -l|--length) need_arg "$1" "$#"; length=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'token': $1";;
    esac
  done
  require_pos_int "--length" "$length"
  require_pos_int "--count" "$count"

  local charset="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local n i idx out
  n=0
  while [ "$n" -lt "$count" ]; do
    out=""
    i=0
    while [ "$i" -lt "$length" ]; do
      rand_index ${#charset}; idx=$_RAND_OUT
      out="${out}${charset:idx:1}"
      i=$((i+1))
    done
    echo "$out"
    n=$((n+1))
  done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  if [ $# -lt 1 ]; then
    usage
    exit 1
  fi

  local sub=$1
  shift || true

  case "$sub" in
    username) cmd_username "$@";;
    password) cmd_password "$@";;
    uuid) cmd_uuid "$@";;
    hex) cmd_hex "$@";;
    base64) cmd_base64 "$@";;
    token) cmd_token "$@";;
    -h|--help) usage;;
    *) err "unknown command '$sub'";;
  esac
}

main "$@"
