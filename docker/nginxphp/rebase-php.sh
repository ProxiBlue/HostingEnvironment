#!/bin/bash
# Swap the PHP build inside a Jelastic nginxphp image for a newer patch release.
#
# Usage: rebase-php.sh <new-version> <install-root-usr-dir>
#
# Jelastic keeps each PHP build in /usr/lib64/jelastic_php/php<version>/ and
# points /usr/bin/php, /usr/sbin/php-fpm, /usr/lib64/php/modules (and friends)
# at it through symlinks. This copies the old tree to the new version dir,
# overlays the fresh build (bundled extensions are replaced, PECL ones kept),
# repoints every symlink, removes the old tree and verifies the result.
set -euo pipefail

NEW_VERSION="$1"
SRC="$2"
BASE=/usr/lib64/jelastic_php

OLD_DIR=$(readlink -f /usr/sbin/php-fpm)
OLD_DIR=${OLD_DIR%/sbin/php-fpm}
OLD_VERSION=${OLD_DIR##*/php}
NEW_DIR="$BASE/php$NEW_VERSION"

[ -d "$OLD_DIR" ] || { echo "cannot locate current PHP tree" >&2; exit 1; }
[ "$OLD_VERSION" != "$NEW_VERSION" ] || { echo "already on $NEW_VERSION" >&2; exit 1; }
[ "${OLD_VERSION%.*}" = "${NEW_VERSION%.*}" ] || {
    echo "minor line mismatch: $OLD_VERSION -> $NEW_VERSION (PECL ABI would break)" >&2; exit 1; }

echo "Rebasing PHP $OLD_VERSION -> $NEW_VERSION"

cp -a "$OLD_DIR" "$NEW_DIR"
for d in bin sbin include lib64 share var etc; do
    [ -d "$SRC/$d" ] && cp -a "$SRC/$d/." "$NEW_DIR/$d/"
done

# Repoint every symlink that referenced the old tree.
find / -xdev -type l -lname "*php$OLD_VERSION*" -print0 2>/dev/null |
while IFS= read -r -d '' link; do
    target=$(readlink "$link")
    ln -sfnT "${target//php$OLD_VERSION/php$NEW_VERSION}" "$link"
done

# Versioned aliases in $BASE/bin (php.8.4.26 -> php.8.4.27, ...).
for link in "$BASE"/bin/*."$OLD_VERSION"; do
    [ -L "$link" ] || continue
    mv "$link" "${link%.$OLD_VERSION}.$NEW_VERSION"
done

rm -rf "$OLD_DIR"

# --- verification: fail the image build on anything off ---
actual=$(php -n -r 'echo PHP_VERSION;')
[ "$actual" = "$NEW_VERSION" ] || { echo "php reports $actual, expected $NEW_VERSION" >&2; exit 1; }

fpm=$(php-fpm -v | head -1)
case "$fpm" in *"PHP $NEW_VERSION "*) ;; *) echo "php-fpm reports: $fpm" >&2; exit 1 ;; esac

if find / -xdev -type l -lname "*php$OLD_VERSION*" 2>/dev/null | grep -q .; then
    echo "symlinks still point at php$OLD_VERSION" >&2; exit 1
fi

missing=$(find "$NEW_DIR/bin" "$NEW_DIR/sbin" "$NEW_DIR/lib64/php/modules" -type f \
    -exec sh -c 'ldd "$1" 2>/dev/null | grep -E "not found|version .* not found" | sed "s|^|$1: |"' _ {} \;)
[ -z "$missing" ] || { echo "unresolved libraries:" >&2; echo "$missing" >&2; exit 1; }

# Every extension the stock php.ini loads must load cleanly under the new binary.
# CLI prints startup warnings on stdout, and the stock ini may route them to a log.
startup=$(php -d display_startup_errors=1 -d log_errors=0 -m 2>&1 | grep -iE 'warning|error|deprecated' || true)
[ -z "$startup" ] || { echo "php startup errors:" >&2; echo "$startup" >&2; exit 1; }

echo "PHP $NEW_VERSION installed at $NEW_DIR"
