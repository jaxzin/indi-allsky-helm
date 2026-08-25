# patches/

Patches applied onto the upstream checkout with `git apply` in lexical order
(`make upstream` performs the checkout, verifies the pin, then applies every
`patches/*.patch`).

Each patch must carry a header comment linking the upstream PR that would
remove it. Patches are a temporary carrying cost: the goal is always to land
the change upstream and delete the patch.

Review rule: A PR changing UPSTREAM_VERSION or UPSTREAM_SHA requires the
reviewer to independently re-resolve the tag via `git ls-remote` — the
Makefile gate only proves the two files agree with each other. See the
"Re-pinning" section of the top-level README for the resolve command.
