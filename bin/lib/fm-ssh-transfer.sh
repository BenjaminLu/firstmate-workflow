#!/usr/bin/env bash
# Dispatch only the child-local command prepared before network Git started.
if [ "${FM_SSH_TRANSFER_ACTIVE:-}" = 1 ] ||
   [ "${FM_SSH_TRANSFER_COMMAND+x}" != x ]; then
  echo 'fm-ssh-transfer: configuration unavailable' >&2
  exit 128
fi
export FM_SSH_TRANSFER_ACTIVE=1
_base="$FM_SSH_TRANSFER_COMMAND"
unset FM_SSH_TRANSFER_COMMAND
# Preserve Git shell-command positional semantics, including quoted identities.
exec /bin/sh -c "$_base \"\$@\"" "$_base" "$@"
