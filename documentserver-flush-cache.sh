#!/bin/bash
# Editor static version derived from its contents.
#
# The image script /usr/bin/documentserver-flush-cache.sh derives the static version (the segment
# /9.4.0-<version>/ in the web-apps, sdkjs, and fonts URLs, which the browser uses as the key for its
# static cache) from the current date and minute. Every container start and every font
# regeneration produces a new version, and nodes brought up at different times get different versions for
# the same files, so the browser downloads the editor again.
#
# This wrapper sits earlier in PATH than /usr/bin and passes the image script a version computed
# from the files being served: one image with the same fonts and plugins yields one version on all
# nodes and after a restart, while any change to those files changes the version. An explicit -h/--hash
# is passed through as is.
set -o pipefail

FLUSH_CACHE=/usr/bin/documentserver-flush-cache.sh
DS_ROOT=/var/www/onlyoffice/documentserver
# md5 of empty input: no files were found, and such a version distinguishes nothing
EMPTY_MD5=d41d8cd98f00b204e9800998ecf8427e

for arg in "$@"; do
  case "$arg" in
    -h|--hash) exec "$FLUSH_CACHE" "$@" ;;
  esac
done

# The plugin manager runs in the background at startup and may update plugins after the last
# call. In that case, once it finishes, the version is recomputed, with an nginx reload.
if [ -z "$FLUSH_CACHE_AFTER_PLUGINS" ] && pgrep -f documentserver-pluginsmanager > /dev/null; then
  (
    while pgrep -f documentserver-pluginsmanager > /dev/null; do sleep 5; done
    FLUSH_CACHE_AFTER_PLUGINS=1 exec "$0"
  ) > /dev/null 2>&1 &
fi

# Only files that nginx can serve are taken: those readable by everyone (the nginx worker is not
# the owner of the files). This keeps out of the version the temporary 0600 files that the
# generators leave at startup under random names (for example, Image__* in the theme
# directories from allthemesgen). Also excluded are compressed copies made from these same files (.gz is made by
# startup, .br by the image build), api.js (the image script renders it from api.js.tpl with this
# version), and the x2t js caches sdk-all.bin, sdk-all.cache (x2t -create-js-cache rewrites them and
# gets different output each time; the browser does not request them).
version=$(cd "$DS_ROOT" && find web-apps sdkjs sdkjs-plugins fonts dictionaries -type f -perm -o=r \
    ! -name '*.gz' ! -name '*.br' ! -name 'sdk-all.bin' ! -name 'sdk-all.cache' \
    ! -path 'web-apps/apps/api/documents/api.js' -print0 \
  | LC_ALL=C sort -z | xargs -0 -r md5sum | md5sum | cut -d ' ' -f 1)
status=$?

if [ "$status" -eq 0 ] && [ -n "$version" ] && [ "$version" != "$EMPTY_MD5" ]; then
  exec "$FLUSH_CACHE" -h "$version" "$@"
fi
echo "documentserver-flush-cache: версию по содержимому вычислить не удалось, версия по времени" >&2
exec "$FLUSH_CACHE" "$@"
