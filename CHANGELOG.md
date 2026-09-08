# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `SECURITY.md` documenting how to report vulnerabilities and what's in scope.

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
