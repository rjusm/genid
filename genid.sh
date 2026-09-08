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

# _filter_out_chars STR EXCLUDE: sets _FILTERED_OUT to STR with every
# character that literally appears in EXCLUDE removed. Deliberately pure
# Bash, not `tr -d`: tr's SET1 argument is a small pattern language, not a
# literal-character list -- a `-` between two characters means a range
# ("3-7" deletes 3,4,5,6,7, not just '3' and '7'), and "[:digit:]"/
# "[=x=]"-shaped substrings are POSIX bracket expressions, not 9-10
# literal characters. A caller's --exclude-chars string could contain any
# of these by coincidence and have it silently delete far more than the
# literal characters they typed. Quoting "$ch" inside the case pattern
# below matches it as a literal string, not a glob, however weird it is.
_filter_out_chars() {
  local str=$1 exclude=$2 out="" i=0 ch
  local len=${#str}
  while [ "$i" -lt "$len" ]; do
    ch=${str:i:1}
    case "$exclude" in
      *"$ch"*) ;;
      *) out="${out}${ch}";;
    esac
    i=$((i+1))
  done
  _FILTERED_OUT=$out
}

# ---------------------------------------------------------------------------
# Output helpers, shared by every generator subcommand.
#
# _NULL_SEP / _ENV_NAME / _ENV_TOTAL are set by each cmd_* function's own
# option parsing (never `local`, since `emit` needs to see them) and reset
# implicitly on every invocation since main() only ever calls one cmd_*.
# ---------------------------------------------------------------------------

_NULL_SEP=0
_ENV_NAME=""
_ENV_TOTAL=1

# emit VALUE INDEX: prints one generated value, honoring --env/--null.
# INDEX is the 1-based position within the current --count batch.
emit() {
  local val=$1 idx=${2:-1}
  if [ -n "$_ENV_NAME" ]; then
    if [ "$_ENV_TOTAL" -gt 1 ]; then
      printf '%s_%d=%s\n' "$_ENV_NAME" "$idx" "$val"
    else
      printf '%s=%s\n' "$_ENV_NAME" "$val"
    fi
  elif [ "$_NULL_SEP" -eq 1 ]; then
    printf '%s\0' "$val"
  else
    printf '%s\n' "$val"
  fi
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

# _now_ms: sets _NOW_MS_OUT to the current Unix time in milliseconds. Uses a
# real millisecond reading when `date` supports the GNU `%N` extension
# (`date +%s%3N`, verified Linux/Git-Bash); falls back to second precision
# (millisecond field always :000) when it doesn't (stock macOS/BSD date has
# no portable sub-second field). The output is validated as exactly 13
# digits -- an unsupported platform may silently echo the format string
# back instead of erroring, so length/digit-shape is checked, not just
# whether the command succeeded.
#
# The fallback deliberately does NOT fill the millisecond field with a
# random value. A random-looking-but-fake sub-second reading would present
# itself as real precision to anyone decoding it later (`genid inspect`
# would print it as if it were the actual millisecond of generation), which
# misrepresents the data. Truncating to the whole second is honest about
# what's actually known here -- it doesn't help or hurt uniqueness or
# cross-second ordering either way, since both are already carried by the
# random tail bits (rand_a/rand_b for uuid v7, the two 40-bit random halves
# for ulid), never by the millisecond field itself.
_now_ms() {
  local candidate secs
  candidate=$(date +%s%3N 2>/dev/null || true)
  case "$candidate" in
    ?????????????) : ;;  # exactly 13 chars, still needs the digit check below
    *) candidate="";;
  esac
  case "$candidate" in
    ''|*[!0-9]*) candidate="";;
  esac
  if [ -n "$candidate" ]; then
    _NOW_MS_OUT=$candidate
  else
    secs=$(date -u +%s)
    _NOW_MS_OUT=$(( secs * 1000 ))
  fi
}

# ---------------------------------------------------------------------------
# Wordlists (compact, built-in)
# ---------------------------------------------------------------------------

ADJ=(brave calm dusty eager fuzzy giant happy icy jolly keen lively misty noble odd proud quiet rapid sharp tidy urban vivid witty young zesty amber bold crisp dark east fine)
NOUN=(otter falcon river cloud tiger maple stone ember delta harbor lynx meadow quartz raven summit tundra vale willow zephyr comet dune ridge fern glade heron ivy jade knoll lark)

# Word pool for `password --mode passphrase` (diceware-style). Intentionally
# NOT claimed to be diceware-equivalent: at ~8.7 bits/word (406 words), a
# 5-word passphrase is ~43 bits, a 6-word one ~52 bits -- decent and easy to
# remember, but nowhere near EFF's 7776-word list (~12.9 bits/word). The
# printed entropy estimate is computed from the real array size, not a
# hardcoded number, so this stays honest if the list ever changes.
PASSPHRASE_WORDS=(
  amber anchor ant apple armor ash axe barley barrel basil basket bay
  beach bean bear bee beetle beige belt bend berry bitter black blade
  blend blue bold bolt boot boulder bowl box brave bread breeze bright
  broad bronze brook brown bucket build butter button cake calm camel candle
  candy canyon cape carrot carry carve catch cave celery chain chair chalk
  chase cheese cherry chisel clam clasp clay clever cliff climb cloak clock
  cloud cloudy clove clutch coast coat cocoa coffee cold comet cool copper
  coral corn crab crane crate crawl creek crimson crisp crow crystal cyan
  damp date dawn deep deer delta desert desk dew dive dolphin drag
  drift drill drop dry duck dune dusk dust dusty eager eagle early
  ember emerald equinox falcon fierce fig finch fjord flame flat float fog
  foggy fold forest forge fork fox fresh frog frost frosty galaxy garlic
  gather gear gecko gentle giant glacier glass glide glove goat gold goose
  grab grand granite grape gravel gray green grip guava gulf hail hammer
  harbor hat haul hawk heavy helmet heron hill hinge hold honest honey
  hornet horse humble humid hunt icy indigo island ivory jade jolly jump
  jungle kind kiwi knife koala ladder lake lamp lantern late leap lemon
  lever lift light lime lion lively loyal lynx magenta mango marble maroon
  marsh mast meadow melon merry meteor mild milk mint mirror mist misty
  mix mold moon moose moth mouse mud muddy mug nail narrow navy
  nebula needle newt night noon oar oat ocean olive onion onyx orange
  orbit otter owl paddle panda papaya peach peak pear pearl pebble pepper
  pie pink plain planet plate pliers plum pond potato pour prairie proud
  pull pulley puma purple push quick quiet rabbit rain rainy raven red
  reef release rice rich ridge river roam robin rock rocky rope rough
  ruby run sage sail salt salty sand sandy sapphire saw scarf scarlet
  screw seal shallow shape shark sheep shelf shield shiny shore shrimp silver
  simple slate slope slow smooth snail snow snowy soar sock solstice sour
  spark spicy spider spill spin spoon spring squid star steep stir stone
  stork storm stormy strait stretch sturdy sugar summit sunny swamp swan sweet
  swift swim syrup table tan tea teal thick thin thread throw thyme
  tiger tiny toad toast tomato topaz torch toss tundra twist valley vase
  vest violet walk wander warm wasp weave whale wheat wheel whisk white
  wide wind windy wise wolf wren wrench yellow zebra zipper
)

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
    -0, --null                    Separate --count output with NUL instead
                               of newline (for `xargs -0`, `read -d ''`).
    -E, --env NAME                Print as NAME=value (or NAME_1=, NAME_2=...
                               with --count > 1) instead of a bare value.

  password [options]
    Generate a cryptographically random password, or a word-based passphrase.
    -m, --mode standard|passphrase
                               "standard" = charset-based password (default).
                               "passphrase" = N random dictionary words.
    -s, --strength low|medium|high|paranoid   (standard mode)
                               low=12 chars alnum, medium=16 +symbols (default),
                               high=20 full charset, paranoid=32 full charset.
    -l, --length N            (standard mode) Overrides preset length.
    -S, --no-symbols           (standard mode) Exclude symbol characters.
    -A, --no-ambiguous          (standard mode) Exclude lookalikes
                               (l, o, I, O, 0, 1); also applies to --charset.
    -C, --charset STR          (standard mode) Use STR as the full character
                               set instead of --strength's classes. Overrides
                               --no-symbols.
    -X, --exclude-chars STR    (standard mode) Remove every character in STR
                               from whichever charset is active (default
                               classes or --charset). Applied after
                               --no-ambiguous.
    -w, --words N              (passphrase mode) Number of words. (default: 5)
    -p, --phrase-sep STR        (passphrase mode) Separator. (default: -)
    -q, --quiet                 Suppress the entropy estimate on stderr.
    -c, --count N                 How many to generate. (default: 1)
    -0, --null                    Separate --count output with NUL instead
                               of newline.
    -E, --env NAME                Print as NAME=value (or NAME_1=, NAME_2=...).
    (Each password/passphrase prints with an estimated entropy in bits, to
    stderr, unless -q/--quiet is given. Passphrase entropy is honest, not
    diceware-grade -- see the PASSPHRASE_WORDS comment in the source.)

  uuid [options]
    Generate an RFC-shaped UUID.
    -v, --version 4|7         v4 = fully random (default). v7 = time-ordered:
                               millisecond timestamp (real ms where `date`
                               supports it, else truncated to the second)
                               + random tail -- good for sortable IDs /
                               DB primary keys (see NOTES).
    -c, --count N                 How many to generate. (default: 1)
    -0, --null                    Separate --count output with NUL instead
                               of newline.
    -E, --env NAME                Print as NAME=value (or NAME_1=, NAME_2=...).

  ulid [options]
    Generate a ULID (Crockford-base32, lexicographically sortable, same
    millisecond timestamp source as `uuid -v 7`). Useful when an external
    system/library expects ULID's format specifically rather than UUID's.
    -c, --count N                 How many to generate. (default: 1)
    -0, --null                    Separate --count output with NUL instead
                               of newline.
    -E, --env NAME                Print as NAME=value (or NAME_1=, NAME_2=...).

  hex [options]
    Generate random data as a hex string.
    -b, --bytes N              Number of random bytes to generate.
    -l, --length N             Output length in hex CHARACTERS instead of
                               bytes (odd N still works: ceil(N/2) bytes are
                               generated, then truncated to N chars).
                               Exactly one of -b/-l is required.
    -c, --count N                 How many to generate. (default: 1)
    -0, --null                    Separate --count output with NUL instead
                               of newline.
    -E, --env NAME                Print as NAME=value (or NAME_1=, NAME_2=...).

  base64 [options]
    Generate random data as base64 text.
    -b, --bytes N              Number of random bytes to generate. (required)
    -c, --count N                 How many to generate. (default: 1)
    -0, --null                    Separate --count output with NUL instead
                               of newline.
    -E, --env NAME                Print as NAME=value (or NAME_1=, NAME_2=...).

  token [options]
    Generate a URL-safe random token (letters, digits, '-', '_'). Handy
    for API keys, session secrets, one-off identifiers.
    -l, --length N             Token length in characters. (default: 32)
    -C, --charset STR          Use STR as the character set instead of the
                               default URL-safe one.
    -X, --exclude-chars STR    Remove every character in STR from the
                               active charset.
    -c, --count N                 How many to generate. (default: 1)
    -0, --null                    Separate --count output with NUL instead
                               of newline.
    -E, --env NAME                Print as NAME=value (or NAME_1=, NAME_2=...).

  inspect VALUE
    Decode a UUID or ULID and print its embedded timestamp (if any). Read-
    only -- does not generate anything. UUIDv4 and non-UUIDv7 versions have
    no embedded timestamp and are reported as such.

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
  - UUID v7 and ULID timestamps use a real millisecond reading when `date`
    supports GNU's `%N` extension (Linux, Git Bash) -- verified via a strict
    13-digit/all-numeric check, since an unsupported `date` may silently
    echo the format string back rather than erroring. Where that's not
    available (stock macOS/BSD date has no portable sub-second field), the
    millisecond field is truncated to :000 rather than filled with a
    random-looking value -- a fabricated sub-second reading would
    misrepresent itself as real precision to anyone decoding it later
    (`genid inspect`). Either way, ordering is always correct between
    different seconds; ordering *within* the same second is never
    meaningful either way (it's carried by the random tail bits, not the
    millisecond field).
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
  local mode="random" length=10 count=1 sep="-" env_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--mode) need_arg "$1" "$#"; mode=$2; shift 2;;
      -l|--length) need_arg "$1" "$#"; length=$2; shift 2;;
      -s|--sep) need_arg "$1" "$#"; sep=$2; shift 2;;
      -0|--null) _NULL_SEP=1; shift;;
      -E|--env) need_arg "$1" "$#"; env_name=$2; shift 2;;
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
  # Force base-10: is_pos_int/require_pos_int only check the *string* shape
  # (via `[ ]`, which is decimal-only), but `$(( ))` arithmetic elsewhere
  # treats a leading zero as octal ("010" -> 8). Without this, a value that
  # validation accepts as "10" could silently generate output for "8"
  # wherever it later hits `$(( ))` instead of a `[ ]`-based loop bound.
  length=$((10#$length))
  count=$((10#$count))
  _ENV_NAME=$env_name
  _ENV_TOTAL=$count

  local charset="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local n
  n=0
  while [ "$n" -lt "$count" ]; do
    local out
    if [ "$mode" = "words" ]; then
      local a no num
      rand_index ${#ADJ[@]}; a=${ADJ[_RAND_OUT]}
      rand_index ${#NOUN[@]}; no=${NOUN[_RAND_OUT]}
      rand_index 90; num=$(( _RAND_OUT + 10 ))
      out="${a}${sep}${no}${sep}${num}"
    else
      local i idx
      out=""
      i=0
      while [ "$i" -lt "$length" ]; do
        rand_index ${#charset}; idx=$_RAND_OUT
        out="${out}${charset:idx:1}"
        i=$((i+1))
      done
    fi
    n=$((n+1))
    emit "$out" "$n"
  done
}

# ---------------------------------------------------------------------------
# password
# ---------------------------------------------------------------------------

cmd_password() {
  local mode="standard"
  local strength="medium" length="" count=1 use_symbols=1 use_ambiguous=1 quiet=0
  local custom_charset="" charset_given=0 exclude_chars=""
  local words=5 phrase_sep="-" env_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--mode) need_arg "$1" "$#"; mode=$2; shift 2;;
      -s|--strength) need_arg "$1" "$#"; strength=$2; shift 2;;
      -l|--length) need_arg "$1" "$#"; length=$2; shift 2;;
      -S|--no-symbols) use_symbols=0; shift;;
      -A|--no-ambiguous) use_ambiguous=0; shift;;
      -C|--charset) need_arg "$1" "$#"; custom_charset=$2; charset_given=1; shift 2;;
      -X|--exclude-chars) need_arg "$1" "$#"; exclude_chars=$2; shift 2;;
      -w|--words) need_arg "$1" "$#"; words=$2; shift 2;;
      -p|--phrase-sep) need_arg "$1" "$#"; phrase_sep=$2; shift 2;;
      -q|--quiet) quiet=1; shift;;
      -0|--null) _NULL_SEP=1; shift;;
      -E|--env) need_arg "$1" "$#"; env_name=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'password': $1";;
    esac
  done
  case "$mode" in
    standard|passphrase) ;;
    *) err "invalid --mode '$mode' (expected standard|passphrase)";;
  esac
  require_pos_int "--count" "$count"
  count=$((10#$count))  # see the base-10 note in cmd_username
  _ENV_NAME=$env_name
  _ENV_TOTAL=$count

  if [ "$mode" = "passphrase" ]; then
    require_pos_int "--words" "$words"
    words=$((10#$words))
    if [ "$words" -lt 2 ]; then
      err "--words must be at least 2 (got: '$words')"
    fi
    local n=0
    while [ "$n" -lt "$count" ]; do
      local parts=() wi=0
      while [ "$wi" -lt "$words" ]; do
        rand_index ${#PASSPHRASE_WORDS[@]}
        parts+=("${PASSPHRASE_WORDS[_RAND_OUT]}")
        wi=$((wi+1))
      done
      local out="" p first=1
      for p in "${parts[@]}"; do
        if [ "$first" -eq 1 ]; then out=$p; first=0; else out="${out}${phrase_sep}${p}"; fi
      done
      n=$((n+1))
      emit "$out" "$n"
      if [ "$quiet" -eq 0 ]; then
        # Entropy is computed from the real wordlist size (see the
        # PASSPHRASE_WORDS comment) -- this is NOT diceware-grade, just an
        # honest number for whatever the built-in list actually provides.
        awk -v wl="${#PASSPHRASE_WORDS[@]}" -v w="$words" \
          'BEGIN{printf "  (wordlist=%d, words=%d, ~%.1f bits entropy)\n", wl, w, w*log(wl)/log(2)}' >&2
      fi
    done
    return
  fi

  if [ "$charset_given" -eq 1 ] && [ -z "$custom_charset" ]; then
    err "--charset must not be empty"
  fi

  case "$strength" in
    low) : "${length:=12}"; use_symbols=0;;
    medium) : "${length:=16}";;
    high) : "${length:=20}";;
    paranoid) : "${length:=32}";;
    *) err "invalid --strength '$strength' (expected low|medium|high|paranoid)";;
  esac
  require_pos_int "--length" "$length"
  length=$((10#$length))  # see the base-10 note in cmd_username

  local classes
  if [ -n "$custom_charset" ]; then
    # --charset replaces the strength-based character classes entirely, so
    # there's only one "class" here -- --no-symbols doesn't apply (there's
    # no separate symbols class to drop). --no-ambiguous still applies
    # below, uniformly, to whatever classes end up in this array.
    classes=("$custom_charset")
  else
    local lower="abcdefghijklmnopqrstuvwxyz"
    local upper="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local digits="0123456789"
    local symbols='!@#$%^&*()-_=+[]{}?'

    classes=("$lower" "$upper" "$digits")
    if [ "$use_symbols" -eq 1 ]; then
      classes+=("$symbols")
    fi
  fi

  if [ "$use_ambiguous" -eq 0 ]; then
    local i
    for i in "${!classes[@]}"; do
      classes[i]=$(printf '%s' "${classes[i]}" | tr -d -- 'loIO01')
    done
  fi

  if [ -n "$exclude_chars" ]; then
    local i
    for i in "${!classes[@]}"; do
      _filter_out_chars "${classes[i]}" "$exclude_chars"
      classes[i]=$_FILTERED_OUT
    done
  fi

  local c
  for c in "${classes[@]}"; do
    [ -n "$c" ] || err "a character class is empty (charset too small once --no-ambiguous/--exclude-chars is applied)"
  done

  local charset=""
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
    n=$((n+1))
    emit "$out" "$n"
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
  done
}

# ---------------------------------------------------------------------------
# uuid
# ---------------------------------------------------------------------------

# uuid_v4/uuid_v7 write their result into _UUID_OUT (same no-subshell
# convention as rand_byte/rand_index -- see the comment at the top of
# "Randomness core") so cmd_uuid can route it through the shared `emit`
# helper (for --env/--null) instead of printing directly.

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
  printf -v _UUID_OUT '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x' "${b[@]}"
}

uuid_v7() {
  # RFC 9562 UUIDv7: 48-bit unix_ts_ms, 4-bit version, 12-bit rand_a,
  # 2-bit variant, 62-bit rand_b. The timestamp comes from _now_ms: a real
  # millisecond reading where `date` supports it (GNU/Linux, Git Bash),
  # otherwise truncated to the second (stock macOS/BSD date) -- see the
  # _now_ms comment for why that's :000 rather than a random offset.
  # Ordering is always correct between UUIDs from different seconds;
  # ordering *within* the same second is never meaningful (uniqueness and
  # any apparent ordering there comes from rand_a/rand_b, not this field).
  _now_ms
  local ms=$_NOW_MS_OUT

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
  printf -v _UUID_OUT '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x' "${b[@]}"
}

cmd_uuid() {
  local version=4 count=1 env_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--version) need_arg "$1" "$#"; version=$2; shift 2;;
      -0|--null) _NULL_SEP=1; shift;;
      -E|--env) need_arg "$1" "$#"; env_name=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'uuid': $1";;
    esac
  done
  require_pos_int "--count" "$count"
  count=$((10#$count))  # see the base-10 note in cmd_username
  _ENV_NAME=$env_name
  _ENV_TOTAL=$count

  local n
  n=0
  while [ "$n" -lt "$count" ]; do
    case "$version" in
      4) uuid_v4;;
      7) uuid_v7;;
      *) err "unsupported UUID version '$version' (only 4 and 7 are supported)";;
    esac
    n=$((n+1))
    emit "$_UUID_OUT" "$n"
  done
}

# ---------------------------------------------------------------------------
# ulid
# ---------------------------------------------------------------------------

CROCKFORD32="0123456789ABCDEFGHJKMNPQRSTVWXYZ"

# _crockford_b32 VALUE NCHARS: sets _B32_OUT to NCHARS Crockford-base32
# characters for VALUE, taken 5 bits at a time from the top. VALUE must fit
# in NCHARS*5 bits -- callers below only ever pass 50-bit-or-less values
# (bash's 64-bit arithmetic handles that comfortably), never the full
# 128-bit ULID at once. That's why ULID's timestamp and randomness halves
# are encoded separately below instead of as one combined bit-accumulator:
# 80 bits of randomness can't fit in a single bash integer, but splitting
# it into two 40-bit (8-char) chunks keeps every value well under 64 bits.
_crockford_b32() {
  local v=$1 nchars=$2 out="" shift_amt idx
  shift_amt=$(( (nchars - 1) * 5 ))
  while [ "$shift_amt" -ge 0 ]; do
    idx=$(( (v >> shift_amt) & 31 ))
    out="${out}${CROCKFORD32:idx:1}"
    shift_amt=$((shift_amt - 5))
  done
  _B32_OUT=$out
}

# ulid_generate: sets _ULID_OUT to one ULID (26 Crockford-base32 chars: 10
# for the 48-bit millisecond timestamp, 16 for 80 bits of randomness).
# Timestamp source is the same _now_ms used by uuid_v7 -- real milliseconds
# where `date` supports it, truncated to the second (:000) otherwise.
ulid_generate() {
  _now_ms
  _crockford_b32 "$_NOW_MS_OUT" 10
  local ts_part=$_B32_OUT

  local i r=0
  i=0
  while [ "$i" -lt 5 ]; do
    rand_byte
    r=$(( (r << 8) | _RAND_OUT ))
    i=$((i+1))
  done
  _crockford_b32 "$r" 8
  local rand_part1=$_B32_OUT

  r=0
  i=0
  while [ "$i" -lt 5 ]; do
    rand_byte
    r=$(( (r << 8) | _RAND_OUT ))
    i=$((i+1))
  done
  _crockford_b32 "$r" 8
  local rand_part2=$_B32_OUT

  _ULID_OUT="${ts_part}${rand_part1}${rand_part2}"
}

cmd_ulid() {
  local count=1 env_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -0|--null) _NULL_SEP=1; shift;;
      -E|--env) need_arg "$1" "$#"; env_name=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'ulid': $1";;
    esac
  done
  require_pos_int "--count" "$count"
  count=$((10#$count))  # see the base-10 note in cmd_username
  _ENV_NAME=$env_name
  _ENV_TOTAL=$count

  local n
  n=0
  while [ "$n" -lt "$count" ]; do
    ulid_generate
    n=$((n+1))
    emit "$_ULID_OUT" "$n"
  done
}

# ---------------------------------------------------------------------------
# hex
# ---------------------------------------------------------------------------

cmd_hex() {
  local bytes="" length="" count=1 env_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -b|--bytes) need_arg "$1" "$#"; bytes=$2; shift 2;;
      -l|--length) need_arg "$1" "$#"; length=$2; shift 2;;
      -0|--null) _NULL_SEP=1; shift;;
      -E|--env) need_arg "$1" "$#"; env_name=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'hex': $1";;
    esac
  done
  if [ -n "$bytes" ] && [ -n "$length" ]; then
    err "--bytes and --length are mutually exclusive for 'hex' (pick one unit)"
  fi
  if [ -n "$length" ]; then
    # --length is in hex CHARACTERS, not bytes -- ceil(length/2) bytes
    # covers it, then the output string is truncated to the exact length
    # below (matters for odd lengths, since 1 byte always yields 2 chars).
    require_pos_int "--length" "$length"
    length=$((10#$length))  # see the base-10 note in cmd_username
    bytes=$(( (length + 1) / 2 ))
  else
    [ -n "$bytes" ] || err "--bytes or --length is required for 'hex'"
    require_pos_int "--bytes" "$bytes"
    bytes=$((10#$bytes))
  fi
  require_pos_int "--count" "$count"
  count=$((10#$count))
  _ENV_NAME=$env_name
  _ENV_TOTAL=$count

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
    if [ -n "$length" ]; then
      out=${out:0:length}
    fi
    n=$((n+1))
    emit "$out" "$n"
  done
}

# ---------------------------------------------------------------------------
# base64
# ---------------------------------------------------------------------------

cmd_base64() {
  local bytes="" count=1 env_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -b|--bytes) need_arg "$1" "$#"; bytes=$2; shift 2;;
      -0|--null) _NULL_SEP=1; shift;;
      -E|--env) need_arg "$1" "$#"; env_name=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'base64': $1";;
    esac
  done
  [ -n "$bytes" ] || err "--bytes is required for 'base64'"
  require_pos_int "--bytes" "$bytes"
  bytes=$((10#$bytes))  # see the base-10 note in cmd_username
  require_pos_int "--count" "$count"
  count=$((10#$count))
  _ENV_NAME=$env_name
  _ENV_TOTAL=$count

  if ! command -v base64 >/dev/null 2>&1 && [ "$HAVE_OPENSSL" -eq 0 ]; then
    err "'base64' subcommand needs either the 'base64' or 'openssl' program on PATH (neither found)"
  fi

  local n i b hexbyte out
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
      out=$( { i=0
        while [ "$i" -lt "$bytes" ]; do
          rand_hex_byte
          hexbyte=$_RAND_HEX_OUT
          printf '%b' "\\x${hexbyte}"
          i=$((i+1))
        done } | base64 | tr -d '\n' )
    else
      out=$(openssl rand -base64 "$bytes" | tr -d '\n')
    fi
    n=$((n+1))
    emit "$out" "$n"
  done
}

# ---------------------------------------------------------------------------
# token
# ---------------------------------------------------------------------------

cmd_token() {
  local length=32 count=1 env_name=""
  local charset="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local charset_given=0 exclude_chars=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -l|--length) need_arg "$1" "$#"; length=$2; shift 2;;
      -C|--charset) need_arg "$1" "$#"; charset=$2; charset_given=1; shift 2;;
      -X|--exclude-chars) need_arg "$1" "$#"; exclude_chars=$2; shift 2;;
      -0|--null) _NULL_SEP=1; shift;;
      -E|--env) need_arg "$1" "$#"; env_name=$2; shift 2;;
      -c|--count) need_arg "$1" "$#"; count=$2; shift 2;;
      *) err "unknown option for 'token': $1";;
    esac
  done
  if [ "$charset_given" -eq 1 ] && [ -z "$charset" ]; then
    err "--charset must not be empty"
  fi
  if [ -n "$exclude_chars" ]; then
    _filter_out_chars "$charset" "$exclude_chars"
    charset=$_FILTERED_OUT
    [ -n "$charset" ] || err "--exclude-chars removed every character from the charset"
  fi
  require_pos_int "--length" "$length"
  length=$((10#$length))  # see the base-10 note in cmd_username
  require_pos_int "--count" "$count"
  count=$((10#$count))
  _ENV_NAME=$env_name
  _ENV_TOTAL=$count
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
    n=$((n+1))
    emit "$out" "$n"
  done
}

# ---------------------------------------------------------------------------
# inspect
# ---------------------------------------------------------------------------

# _epoch_to_utc SECS: sets _EPOCH_STR_OUT to a "YYYY-MM-DD HH:MM:SS" UTC
# rendering of the Unix timestamp SECS. Tries GNU date's `-d @SECS` first
# (Linux, Git Bash), then BSD/macOS date's `-r SECS`, matching the
# try-one-then-fall-back approach used elsewhere in this script (HAVE_OPENSSL,
# _now_ms) for the same GNU-vs-BSD portability gap.
_epoch_to_utc() {
  local secs=$1 out
  if out=$(date -u -d "@${secs}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null); then
    _EPOCH_STR_OUT=$out
  elif out=$(date -u -r "$secs" '+%Y-%m-%d %H:%M:%S' 2>/dev/null); then
    _EPOCH_STR_OUT=$out
  else
    _EPOCH_STR_OUT="<could not format date on this platform>"
  fi
}

cmd_inspect() {
  [ $# -ge 1 ] || err "'inspect' requires a value to decode"
  local value=$1 lower upper

  lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  upper=$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')

  if [ "${#lower}" -eq 36 ] \
    && [ "${lower:8:1}" = "-" ] && [ "${lower:13:1}" = "-" ] \
    && [ "${lower:18:1}" = "-" ] && [ "${lower:23:1}" = "-" ]; then
    local stripped=${lower//-/}
    case "$stripped" in
      *[!0-9a-f]*) stripped="";;
    esac
    if [ -n "$stripped" ] && [ "${#stripped}" -eq 32 ]; then
      local version=${stripped:12:1}
      echo "Format: UUID"
      echo "Version: $version"
      if [ "$version" = "7" ]; then
        local ms_hex ms secs
        ms_hex=${stripped:0:12}
        ms=$((16#$ms_hex))
        secs=$(( ms / 1000 ))
        _epoch_to_utc "$secs"
        printf 'Timestamp: %s.%03d UTC\n' "$_EPOCH_STR_OUT" "$(( ms % 1000 ))"
      else
        echo "Timestamp: not embedded (only UUIDv7 carries one; this is v$version)"
      fi
      return
    fi
  fi

  if [ "${#upper}" -eq 26 ]; then
    case "$upper" in
      *[!0-9A-HJKMNP-TV-Z]*) : ;;
      *)
        local ts_chars val i idx c
        ts_chars=${upper:0:10}
        val=0
        i=0
        while [ "$i" -lt 10 ]; do
          c=${ts_chars:i:1}
          idx=${CROCKFORD32%%"$c"*}
          idx=${#idx}
          val=$(( (val << 5) | idx ))
          i=$((i+1))
        done
        local ms=$(( val & 0xFFFFFFFFFFFF ))
        local secs=$(( ms / 1000 ))
        _epoch_to_utc "$secs"
        echo "Format: ULID"
        printf 'Timestamp: %s.%03d UTC\n' "$_EPOCH_STR_OUT" "$(( ms % 1000 ))"
        return
        ;;
    esac
  fi

  err "unrecognized format: expected a UUID (8-4-4-4-12 hex) or a 26-character ULID"
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
    ulid) cmd_ulid "$@";;
    hex) cmd_hex "$@";;
    base64) cmd_base64 "$@";;
    token) cmd_token "$@";;
    inspect) cmd_inspect "$@";;
    -h|--help) usage;;
    *) err "unknown command '$sub'";;
  esac
}

main "$@"
