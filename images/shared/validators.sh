#!/bin/bash
# Input validators shared by every entrypoint in these images.
#
# SOURCED, never executed — it defines functions and does nothing else. It
# carries no `set -o` lines: the sourcing script owns its own shell options.
#
# This file exists because require_bool was previously duplicated verbatim in
# render-flask-config.sh and entrypoint-daemon.sh. Six identical lines are
# cheap to copy and expensive to keep honest: the two copies could drift, and
# the claim these images make — "every boolean is validated the same way, and
# `True` is rejected by name" — is only literally true with one definition.
#
# NEVER add `set -x` to a script that sources this. These functions handle the
# database password, SECRET_KEY, PASSWORD_KEY and the OIDC client secret. For
# the same reason, no message below ever echoes the offending value: only its
# length in bytes, which is enough to tell an empty variable from a wrong one
# without putting a credential in a pod log.
#
# CALLING CONVENTION — each validator must be the ENTIRE right-hand side of its
# own assignment:
#
#     VALUE="$(require_nonempty NAME "${NAME:-}")"
#     VALUE="$(require_charset NAME "$VALUE" "$CLASS" 'description')"
#
# Never nest them:
#
#     VALUE="$(require_charset NAME "$(require_nonempty NAME "$X")" ...)"   # WRONG
#
# `exit 1` inside a command substitution terminates only that substitution.
# Nested, the inner failure yields "" to the outer call and the enclosing
# assignment still succeeds, so errexit never fires and a validated-looking
# empty value flows on. Sequenced, each assignment takes the validator's own
# exit status and errexit aborts the script.

# $1=name  $2=value — must be exactly the string true or false.
require_bool() {
    case "$2" in
        true|false) printf '%s' "$2" ;;
        *) printf 'FATAL: %s must be exactly "true" or "false" (got %d bytes)\n' "$1" "${#2}" >&2; exit 1 ;;
    esac
}

# $1=name  $2=value — must be a JSON array of strings.
#
# jq's --argjson accepts ANY well-formed JSON, which turns an operator typo
# into a silent fail-open rather than an error:
#   * OIDC_ALLOWED_GROUPS=null   -> falsy at auth_views.py:238, so the group
#                                   allow-list stops filtering entirely.
#   * OIDC_ADMIN_GROUPS="admins" -> truthy at auth_views.py:291, where
#                                   set("admins") is a set of CHARACTERS, so
#                                   any group sharing one letter grants admin.
require_string_array() {
    printf '%s' "$2" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null \
        || { printf 'FATAL: %s must be a JSON array of strings, e.g. ["group1"]\n' "$1" >&2; exit 1; }
    printf '%s' "$2"
}

# $1=name  $2=value — must not be the empty string.
require_nonempty() {
    if [ -z "$2" ]; then
        printf 'FATAL: %s must be set and non-empty\n' "$1" >&2
        exit 1
    fi
    printf '%s' "$2"
}

# $1=name  $2=value  $3=allowed-character-class  $4=human description
#
# For values that land in the DSN but must NOT be percent-encoded, because
# SQLAlchemy does not decode them (see render-flask-config.sh). A character
# class keeps the property that matters — nothing that could introduce a URI
# delimiter, an extra query parameter or a different host gets through —
# without the round-trip corruption encoding would cause.
#
# The empty-string rejection is not redundant with require_nonempty: the
# `*[!class]*` pattern needs at least one character to match, so "" would
# otherwise be accepted as valid. That is precisely how a nested
# require_charset/require_nonempty call once produced an empty DSN component.
# Rejecting "" here closes the class regardless of call-site discipline.
require_charset() {
    if [ -z "$2" ]; then
        printf 'FATAL: %s must be set and non-empty\n' "$1" >&2
        exit 1
    fi
    case "$2" in
        *[!$3]*)
            printf 'FATAL: %s may contain only %s (got %d bytes)\n' "$1" "$4" "${#2}" >&2
            exit 1 ;;
    esac
    printf '%s' "$2"
}
