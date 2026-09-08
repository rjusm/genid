# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `SECURITY.md` documenting how to report vulnerabilities and what's in scope.
- `-C`/`--charset` for `password` and `token`, to fully override the
  built-in character set (e.g. for systems with restrictive charset
  requirements). `--no-ambiguous` applies to a custom charset too.
- `ulid` command: Crockford-base32 ULIDs, using the same millisecond
  timestamp source as `uuid -v 7`.
- `inspect VALUE` command: decodes a UUID or ULID and prints its embedded
  timestamp (UUIDv7/ULID only -- other versions report "not embedded").
- `password -m passphrase`: word-based passphrases (`-w`/`--words`,
  `-p`/`--phrase-sep`), from a built-in ~400-word list. Prints an honest
  entropy estimate on stderr -- not claimed as diceware-grade.
- `-0`/`--null`: NUL-separated `--count` output, for `xargs -0`-style
  pipelines. Available on every generator subcommand.
- `-E`/`--env NAME`: print output as `NAME=value` (or `NAME_1=`, `NAME_2=`...
  with `--count` > 1) for dropping straight into `.env` files. Available on
  every generator subcommand.
- `uuid -v 7` and `ulid` now use a real millisecond timestamp when `date`
  supports GNU's `%N` extension (Linux, Git Bash), instead of always
  padding second-accuracy with a random tail.

### Fixed
- `genid.bat` didn't propagate Git's `usr\bin`/`bin` onto `PATH` before
  invoking `bash.exe` directly, so `genid.sh` failed with "command not
  found" for `awk`/`cat`/`tr`/etc. on a plain `cmd.exe` PATH.

## [1.0.0] - 2026-09-08

First tagged release.

### Added
- `genid.sh`: username, password, uuid (v4/v7), hex, base64, and token
  generation, using `/dev/urandom`/`openssl` with rejection sampling
  (never `$RANDOM`).
- `tests.sh`: automated test suite covering all subcommands, input
  validation, randomness sanity checks, and the openssl-less fallback path.
- CI (GitHub Actions) running ShellCheck and the test suite on Linux,
  macOS, and Windows (via Git Bash).
- `LICENSE` (MIT).
- `.gitattributes` pinning shell scripts to LF line endings.
- README installation instructions (user-level and system-wide).
