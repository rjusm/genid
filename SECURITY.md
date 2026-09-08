# Security Policy

genid.sh is used to generate passwords, tokens, and other secrets, so its
randomness and its command-line handling are both security-sensitive.

## Supported Versions

Only the latest release is supported. Please update before reporting an
issue if you're on an older tag.

## Reporting a Vulnerability

Please **do not** open a public issue for security vulnerabilities.

Instead, use [GitHub Security Advisories](https://github.com/rjusm/genid/security/advisories/new)
to report privately. Include:

- The version/commit affected.
- Steps to reproduce.
- The potential impact (e.g., predictable/biased output, weakened entropy).

You should get an initial response within a few days.

## Scope

In scope: anything that could make generated output predictable or less
random than advertised (e.g., a flaw in the rejection-sampling logic, a
fallback path that silently weakens the entropy source, `$RANDOM` or
another non-cryptographic source being used instead of
`/dev/urandom`/`openssl`), and command-injection or similar issues in
argument handling.

Out of scope: the known, documented limitations already called out in
`genid.sh --help` (e.g., UUIDv7's second-granularity timestamp, or the
password entropy estimate being an upper bound).
