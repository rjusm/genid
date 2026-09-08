<p align="center">
  <a href="https://github.com/rjusm/genid/actions/workflows/ci.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/rjusm/genid/ci.yml?branch=main&style=for-the-badge&label=CI" alt="CI status">
  </a>
  <img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash 3.2+">
  <img src="https://img.shields.io/badge/dependencies-none-black?style=for-the-badge" alt="No dependencies">
  <img src="https://img.shields.io/badge/license-MIT-black?style=for-the-badge" alt="MIT License">
</p>

<h1 align="center">genid.sh</h1>

<p align="center">
  <b>A portable random data generator, in a single bash script.</b><br>
  Passwords, usernames, UUIDs, hex, base64, tokens — no dependencies, no runtime, no fuss.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/linux-✓-black?style=flat-square" alt="Linux">
  <img src="https://img.shields.io/badge/macos-✓-black?style=flat-square" alt="macOS">
  <img src="https://img.shields.io/badge/windows_(wsl%2Fgit--bash)-✓-black?style=flat-square" alt="Windows">
</p>

<br>

```bash
chmod +x genid.sh
./genid.sh password
```

<br>

## ➜ Installation

**User-level (no root required):**
```bash
mkdir -p ~/.local/bin && curl -sSL https://raw.githubusercontent.com/rjusm/genid/main/genid.sh -o ~/.local/bin/genid && chmod +x ~/.local/bin/genid
```
(Make sure `~/.local/bin` is on your `$PATH`.)

**System-wide (requires sudo):**
```bash
curl -sSL https://raw.githubusercontent.com/rjusm/genid/main/genid.sh | sudo tee /usr/local/bin/genid >/dev/null && sudo chmod +x /usr/local/bin/genid
```

Or skip installing anything and just clone + run:
```bash
git clone https://github.com/rjusm/genid.git && cd genid && chmod +x genid.sh
```

<br>

## ➜ Usage

```bash
./genid.sh password                      # 16-char password with symbols
./genid.sh password -s paranoid          # 32-char, full charset
./genid.sh password -s high -A -q        # 20-char, no ambiguous chars, no entropy line

./genid.sh username                      # random 10-char alnum username
./genid.sh username -m words             # e.g. "brave-otter-42"

./genid.sh uuid                          # UUID v4 (random)
./genid.sh uuid -v 7                     # UUID v7 (time-ordered, sortable)

./genid.sh hex -b 32                     # 32 random bytes as hex
./genid.sh base64 -b 32                  # 32 random bytes as base64
./genid.sh token -l 64                   # 64-char URL-safe token (API keys, secrets)

./genid.sh password -c 5                 # generate 5 at once
```

Run `./genid.sh --help` for the full flag reference.

<br>

## ➜ Testing

```bash
chmod +x tests.sh
./tests.sh
```

<br>

## ➜ Why

Because `pwgen`, `uuidgen`, and `openssl rand` all do one thing well, but none of them are guaranteed to be installed — and reaching for Python or Node for this is overkill. `genid.sh` is one file, works wherever `bash` does, and never touches `$RANDOM`.

<br>

<p align="center">
  <sub>Built with bash, <code>/dev/urandom</code>, and rejection sampling.</sub>
</p>

<p align="center">
genid.sh is open-sourced software licensed under the <a href="LICENSE">MIT license</a>.
</p>
