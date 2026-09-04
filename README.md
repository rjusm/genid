# genid.sh

Portable random data generator: usernames, passwords, UUIDs, hex, base64, tokens. No dependencies.

```bash
chmod +x genid.sh
```

## Examples

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

Full flag reference: `./genid.sh --help`
