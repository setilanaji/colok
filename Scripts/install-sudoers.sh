#!/bin/bash
# Grants the current user exactly the two privileged operations Colok needs,
# with fixed argument vectors. Nothing else. Remove with:
#   sudo rm /etc/sudoers.d/colok
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "run with sudo: sudo bash $0" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-$(logname)}"
TMP="$(mktemp)"
HERE="$(cd "$(dirname "$0")" && pwd)"

# The Internet Sharing helper must be root-owned and not user-writable, or
# whitelisting it in sudoers would hand the user a root shell.
install -d -m 0755 -o root -g wheel /usr/local/libexec
install -m 0755 -o root -g wheel "$HERE/colok-share" /usr/local/libexec/colok-share
echo "installed /usr/local/libexec/colok-share"

cat > "$TMP" <<RULE
# Installed by Colok for ${TARGET_USER}.
Cmnd_Alias COLOK_TETHER = /usr/bin/AssetCacheTetheratorUtil enable, \\
                          /usr/bin/AssetCacheTetheratorUtil disable, \\
                          /usr/bin/AssetCacheTetheratorUtil -j enable, \\
                          /usr/bin/AssetCacheTetheratorUtil -j disable, \\
                          /usr/bin/AssetCacheTetheratorUtil -j isEnabled
Cmnd_Alias COLOK_CACHE  = /usr/bin/AssetCacheManagerUtil activate, \\
                          /usr/bin/AssetCacheManagerUtil deactivate
Cmnd_Alias COLOK_SHARE  = /usr/local/libexec/colok-share
${TARGET_USER} ALL=(root) NOPASSWD: COLOK_TETHER, COLOK_CACHE, COLOK_SHARE
RULE

# Never install a file that would break sudo.
if ! visudo -cf "$TMP"; then
  echo "generated sudoers rule failed validation, aborting" >&2
  rm -f "$TMP"
  exit 1
fi

install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/colok
rm -f "$TMP"
echo "installed /etc/sudoers.d/colok for ${TARGET_USER}"
