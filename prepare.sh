#!/usr/bin/env bash
# Prepares the overlay image build context from the results of the vanilla build
# (sdkjs/deploy/sdkjs and web-apps/deploy/web-apps).
#
# Performs those steps of the official DocumentServer packaging that are absent from the JS build
# (found in build_tools/scripts/deploy_server.py):
#   1. inlines the embed worker into api.js     — deploy_server.py:132
#   2. substitutes the cache version ?_dc=<ver>-<build> — done by document-server-package
#   3. removes *.js.map                          — deploy_server.py:124-126
#   4. puts the result as api.js.tpl             — api.js is rendered at container start
#      by documentserver-flush-cache.sh (cp api.js.tpl api.js + sed on {{HASH_POSTFIX}})
#
# The script is idempotent: the context is recreated from scratch on every run. It is assembled in the
# neighboring context.tmp directory and renamed to context by the last command, so
# the context directory in an incomplete state does not exist even for an instant: an interrupted preparation
# leaves context.tmp, which the next run deletes.
#
#   bash overlay/prepare.sh                                   # normal preparation
#   bash overlay/prepare.sh --override SOURCE_TAG=v9.4.0.130   # a different pin, locally
#   bash overlay/prepare.sh --allow-no-reference               # no verification: no reference on the machine
#   bash overlay/prepare.sh --help                             # help
set -euo pipefail

# --- parameters --------------------------------------------------------------
OVERLAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The fork root is needed only for the defaults: in the pipeline the sources do not lie next to
# overlay, and each directory is set by its own variable there.
FORK_DIR="${FORK_DIR:-$(cd "$OVERLAY_DIR/.." && pwd)}"

# shellcheck source=lib.sh
. "$OVERLAY_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Подготовка контекста сборки overlay-образа OnlyOffice Document Server.

  bash prepare.sh [--override КЛЮЧ=значение]... [--allow-no-reference]

Закрепления — versions.env рядом со скриптом, и это единственный их источник: переменная
окружения с именем ключа файл не перекрывает. Осознанное отступление задаётся аргументом;
конвейер передаёт свои адреса через --override точно так же:

  --override КЛЮЧ=значение   собрать с другим закреплением; флаг повторяемый, ключ обязан
                             входить в состав versions.env
  --allow-no-reference       пропустить сверку api.js.tpl, когда эталона на машине нет;
                             без флага недоступный эталон — отказ

Переменные окружения (пути, а не закрепления):
  FORK_DIR         корень форка для путей по умолчанию (по умолчанию — каталог над overlay)
  WEBAPPS_DIR, SDKJS_DIR, SDKJS_FORMS_DIR, BUILD_TOOLS_DIR
                   клоны-источники и клон сборочных скриптов
  SOURCES_DIR      каталог .sdk-minify от build-static.sh (по умолчанию — FORK_DIR)
  REFERENCE_TPL    эталонный api.js.tpl для сверки, когда EXPECTED_API_TPL_SHA256 пуст
  CONTEXT_DIR      каталог контекста; обязан лежать внутри overlay и заканчиваться на context
USAGE
}

# Skipping the verification is only by an explicit flag, and the pipeline does not pass it, so the api.js.tpl verification
# is mandatory there by construction. The variable name is lowercase on purpose: an uppercase
# ALLOW_NO_REFERENCE would read as a contract with the environment, and the environment has nothing to do with it:
# the execution mode does not affect whether the verification is mandatory.
allow_no_reference=0

# The arguments are parsed before the pins are read: overrides must be known
# before the file is read.
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --override)
      [ $# -ge 2 ] || {
        echo "ОШИБКА: --override без значения — ожидалось КЛЮЧ=значение" >&2
        echo "  справка: bash prepare.sh --help" >&2
        exit 1
      }
      add_version_override "$2"
      shift 2
      ;;
    --allow-no-reference)
      allow_no_reference=1
      shift
      ;;
    *)
      echo "ОШИБКА: неизвестный аргумент '$1'" >&2
      echo "  справка: bash prepare.sh --help" >&2
      exit 1
      ;;
  esac
done

# The pins are read before any checks: there is nothing to check until it is known what is pinned.
read_versions "$OVERLAY_DIR"
require_keys "$OVERLAY_DIR/versions.env" '' SOURCE_TAG BUILD_TOOLS_REV PRODUCT_VERSION BUILD_NUMBER

# The source directories are the only overridable points. Everything else (deploy/,
# common/embed, scripts/) is derived from them: see the derived-paths check below.
WEBAPPS_DIR="${WEBAPPS_DIR:-$FORK_DIR/web-apps}"
SDKJS_DIR="${SDKJS_DIR:-$FORK_DIR/sdkjs}"
SDKJS_FORMS_DIR="${SDKJS_FORMS_DIR:-$FORK_DIR/sdkjs-forms}"
BUILD_TOOLS_DIR="${BUILD_TOOLS_DIR:-$FORK_DIR/_ref/build_tools}"
SOURCES_DIR="${SOURCES_DIR:-$FORK_DIR}"
read_sdk_minify "$SOURCES_DIR"

webapps_deploy="$WEBAPPS_DIR/deploy/web-apps"
sdkjs_deploy="$SDKJS_DIR/deploy/sdkjs"
embed_dir="$SDKJS_DIR/common/embed"
build_tools_scripts="$BUILD_TOOLS_DIR/scripts"

CONTEXT_DIR="${CONTEXT_DIR:-$OVERLAY_DIR/context}"
# The reference for verifying the post-processing. The verification is mandatory: it is the only one that checks that
# the code executed during preparation did not change api.js. The deliberate bypass, when there is no reference on the
# machine, is the --allow-no-reference flag, parsed above.
REFERENCE_TPL="${REFERENCE_TPL:-$FORK_DIR/_ref/image/web-apps/apps/api/documents/api.js.tpl}"

API_REL="apps/api/documents/api.js"

log() { printf '==> %s\n' "$*"; }

# --- source data checks ------------------------------------------------------
# Derived paths are rejected rather than silently replaced: a directory set bypassing the rules would lead
# the build away from the clone whose tag and revision were checked. One directory would be verified, while the
# contents of another would go into the image.
for var in BUILD_TOOLS_SCRIPTS SDKJS_DEPLOY WEBAPPS_DEPLOY EMBED_DIR; do
  [ -z "${!var:-}" ] || {
    echo "ОШИБКА: $var не поддерживается — путь выводится из каталога источника" >&2
    echo "  каталоги задаются так: WEBAPPS_DIR, SDKJS_DIR, SDKJS_FORMS_DIR, BUILD_TOOLS_DIR" >&2
    echo "  из них выводятся deploy/, common/embed и scripts/: проверка ревизии и сборка идут по одному каталогу" >&2
    exit 1
  }
done

for d in "$sdkjs_deploy" "$webapps_deploy" "$embed_dir"; do
  [ -d "$d" ] || { echo "ОШИБКА: нет каталога $d — сначала выполни сборку (см. README)" >&2; exit 1; }
done
[ -f "$build_tools_scripts/base.py" ] || {
  echo "ОШИБКА: нет $build_tools_scripts/base.py — sdkjs/common/embed/make.py импортирует base из build_tools" >&2
  exit 1
}
# The worker to inline: without the file make.py will run, but api.js will be left without embed mode,
# and the discrepancy would surface only at the verification, as a message about mismatched bytes.
[ -f "$embed_dir/embed.min.js" ] || {
  echo "ОШИБКА: нет $embed_dir/embed.min.js — вклеивать в api.js нечего" >&2
  exit 1
}

# The version and build number are substituted into a sed expression (step 3a), so the format
# is checked in advance: a '/' character in the value would end the substitution expression early.
[[ "$PRODUCT_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
  echo "ОШИБКА: PRODUCT_VERSION='$PRODUCT_VERSION' — ожидались только цифры и точки" >&2
  exit 1
}
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "ОШИБКА: BUILD_NUMBER='$BUILD_NUMBER' — ожидались только цифры" >&2
  exit 1
}

# The build_tools revision: code from this clone is executed in step 3b, so a mismatch
# with the pinned revision stops the preparation before make.py runs.
build_tools_head=$(git -C "$BUILD_TOOLS_DIR" rev-parse HEAD 2>/dev/null || true)
[ -n "$build_tools_head" ] || {
  echo "ОШИБКА: $BUILD_TOOLS_DIR не git-клон — ревизию build_tools проверить нечем" >&2
  exit 1
}
[ "$build_tools_head" = "$BUILD_TOOLS_REV" ] || {
  echo "ОШИБКА: build_tools на другой ревизии" >&2
  echo "  ожидалось: $BUILD_TOOLS_REV" >&2
  echo "  получено:  $build_tools_head  ($BUILD_TOOLS_DIR)" >&2
  echo "  нужная ревизия достаётся так:" >&2
  echo "    git -C '$BUILD_TOOLS_DIR' fetch --depth 1 origin $BUILD_TOOLS_REV" >&2
  echo "    git -C '$BUILD_TOOLS_DIR' checkout $BUILD_TOOLS_REV" >&2
  echo "  осознанный переход на другую ревизию: --override BUILD_TOOLS_REV=<полный SHA>" >&2
  exit 1
}
# One revision is not enough: an edit in the build_tools working tree changes the executed code without
# moving HEAD. Only tracked files are looked at: there are no untracked artifacts in this
# clone, and we do not run the full build_tools build.
build_tools_dirty=$(git -C "$BUILD_TOOLS_DIR" status --porcelain --untracked-files=no)
[ -z "$build_tools_dirty" ] || {
  echo "ОШИБКА: рабочее дерево build_tools изменено — исполнялся бы код не закреплённой ревизии" >&2
  echo "$build_tools_dirty" | sed 's/^/  /' >&2
  echo "  сброс: git -C '$BUILD_TOOLS_DIR' checkout -- ." >&2
  exit 1
}
log "build_tools закреплён: $build_tools_head (скрипты: $build_tools_scripts)"

# The source clones: the context is built from their deploy/, so the tag pin is symmetric to
# the build_tools pin, otherwise a build of an unknown commit would end up in the image. The revisions
# are remembered right here: they go into the readiness stamp, and they must not be asked for again,
# because HEAD of the directory could move between the check and the write.
[ -n "$SOURCE_TAG" ] || { echo "ОШИБКА: SOURCE_TAG пуст" >&2; exit 1; }
for pair in "WEB_APPS_REV:$WEBAPPS_DIR" "SDKJS_REV:$SDKJS_DIR" "SDKJS_FORMS_REV:$SDKJS_FORMS_DIR"; do
  rev_var="${pair%%:*}"
  repo_dir="${pair#*:}"
  repo_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
  [ -n "$repo_head" ] || {
    echo "ОШИБКА: $repo_dir не git-клон — тег источника проверить нечем" >&2
    exit 1
  }
  # The list of tags is taken into a variable, the comparison is without a pipe: grep -q closes the pipe
  # after the first match, and with pipefail a successful check would fail with SIGPIPE.
  repo_tags=$(git -C "$repo_dir" tag --points-at HEAD)
  grep -qxF "$SOURCE_TAG" <<<"$repo_tags" || {
    echo "ОШИБКА: $(basename "$repo_dir") не на теге $SOURCE_TAG" >&2
    echo "  каталог:      $repo_dir" >&2
    echo "  HEAD:         $repo_head" >&2
    echo "  теги на HEAD: ${repo_tags//$'\n'/ }" >&2
    echo "  нужный тег:   git -C '$repo_dir' checkout $SOURCE_TAG" >&2
    echo "  осознанная сборка с другого тега: --override SOURCE_TAG=<тег>" >&2
    exit 1
  }
  printf -v "$rev_var" '%s' "$repo_head"
done
log "источники на теге $SOURCE_TAG: $WEBAPPS_DIR, $SDKJS_DIR, $SDKJS_FORMS_DIR"

# The explicit pin or the availability of the reference (step 4) is checked before copying.
if [ -n "$EXPECTED_API_TPL_SHA256" ]; then
  [[ "$EXPECTED_API_TPL_SHA256" =~ ^[a-f0-9]{64}$ ]] || {
    echo "ОШИБКА: EXPECTED_API_TPL_SHA256 — ожидалось 64 строчных шестнадцатеричных знака" >&2
    exit 1
  }
elif [ ! -f "$REFERENCE_TPL" ]; then
  if [ "$allow_no_reference" = "1" ]; then
    log "ПРЕДУПРЕЖДЕНИЕ: эталон $REFERENCE_TPL недоступен, сверка будет пропущена (--allow-no-reference)"
  else
    echo "ОШИБКА: эталон $REFERENCE_TPL недоступен — сверять api.js.tpl не с чем" >&2
    echo "  эталон восстанавливается командами из README, раздел «Проверка эквивалентности»" >&2
    echo "  осознанный пропуск сверки: аргумент --allow-no-reference" >&2
    exit 1
  fi
fi

# Below, directories are deleted recursively (chmod -R, rm -rf), so the path is checked before, not
# after: a wrong CONTEXT_DIR value would cost someone else's directory. Ownership
# is checked against the overlay directory, not the fork root: in the pipeline the sources lie in a different
# place, while the context is always next to the script, otherwise the Dockerfile will not find it (COPY takes
# context/ relative to the build context root).
[ -n "$CONTEXT_DIR" ] || { echo "ОШИБКА: CONTEXT_DIR пуст" >&2; exit 1; }
context_abs=$(realpath -m "$CONTEXT_DIR")
overlay_abs=$(realpath -m "$OVERLAY_DIR")
[ "$(basename "$context_abs")" = "context" ] || {
  echo "ОШИБКА: последним элементом CONTEXT_DIR должен быть 'context', получено: $context_abs" >&2
  exit 1
}
case "$context_abs/" in
  "$overlay_abs"/*) ;;
  *)
    echo "ОШИБКА: CONTEXT_DIR должен лежать внутри $overlay_abs, получено: $context_abs" >&2
    exit 1
    ;;
esac
CONTEXT_DIR="$context_abs"
STAGING_DIR="$CONTEXT_DIR.tmp"

# --- 1. staging directory from scratch ---------------------------------------
# Files are made read-only (as in the image), so before deletion
# the write permission is restored, otherwise rm -rf would refuse even the owner.
for dir in "$CONTEXT_DIR" "$STAGING_DIR"; do
  if [ -d "$dir" ]; then
    chmod -R u+w "$dir"
    rm -rf "$dir"
  fi
done
mkdir -p "$STAGING_DIR"
log "промежуточный каталог: $STAGING_DIR"

cp -a "$sdkjs_deploy"   "$STAGING_DIR/sdkjs"
cp -a "$webapps_deploy" "$STAGING_DIR/web-apps"
log "скопировано: sdkjs ($(du -sh "$STAGING_DIR/sdkjs" | cut -f1)), web-apps ($(du -sh "$STAGING_DIR/web-apps" | cut -f1))"

# --- 2. remove *.js.map (deploy_server.py:124-126) ----------------------------
maps=$(find "$STAGING_DIR" -name '*.js.map' -type f -print -delete | wc -l)
log "удалено *.js.map: $maps"

# --- 3. api.js post-processing ------------------------------------------------
api_path="$STAGING_DIR/web-apps/$API_REL"
[ -f "$api_path" ] || { echo "ОШИБКА: нет $api_path" >&2; exit 1; }
chmod u+w "$api_path"

# 3a. cache version: the source has "?_dc=0" baked in, the image has "?_dc=<version>-<build>".
#     The substitution is done by the document-server-package packaging; it is not in build_tools.
dc_before=$(grep -c '"?_dc=0"' "$api_path" || true)
[ "$dc_before" -eq 1 ] || {
  echo "ОШИБКА: ожидал ровно одно вхождение \"?_dc=0\" в api.js, нашёл $dc_before" >&2
  exit 1
}
sed -i "s/\"?_dc=0\"/\"?_dc=${PRODUCT_VERSION}-${BUILD_NUMBER}\"/" "$api_path"
log "кеш-версия: ?_dc=${PRODUCT_VERSION}-${BUILD_NUMBER}"

# 3b. embed worker: sdkjs/common/embed/make.py inlines embed.min.js into api.js.
#     make.py does sys.path.append('../../../build_tools/scripts'), while the build_tools clone
#     lies separately (by default in the local working directory _ref/ of the fork root),
#     so base is supplied through PYTHONPATH.
( cd "$embed_dir" && PYTHONPATH="$build_tools_scripts" python3 make.py "$api_path" )
grep -q 'AscEmbedGlobalScroller' "$api_path" || {
  echo "ОШИБКА: embed-воркер не вклеился в api.js" >&2; exit 1; }
log "embed-воркер вклеен (make.py)"

# 3c. the result is the api.js.tpl template; api.js itself is rendered at container start.
mv "$api_path" "$api_path.tpl"
log "api.js -> api.js.tpl"

# --- 4. verification against the pin or the image reference ------------------------------------
# The sum is always computed, not only for the verification: it goes into the stamp and into the image label,
# by which the results of a local build and the pipeline are compared.
API_TPL_SHA256=$(sha256sum "$api_path.tpl" | cut -d' ' -f1)
check_api_template "$api_path.tpl" "$REFERENCE_TPL" "$EXPECTED_API_TPL_SHA256" "$allow_no_reference"

# --- 5. readiness stamp -------------------------------------------------------
# It is written before permissions are set: after chmod the context root becomes 0555, and a file
# can no longer be created in it. The stamp is the only confirmation that the context was assembled in full:
# without it build.sh will not build the image, and the provenance labels are taken from here.
# The variable names match the stamp keys (STAMP_KEYS in lib.sh), so there is one list of keys
# for both writing and reading.
BUILD_TOOLS_REV="$build_tools_head"
PREPARED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
for key in "${STAMP_KEYS[@]}"; do
  printf '%s=%s\n' "$key" "${!key}"
done > "$STAGING_DIR/$STAMP_NAME"
log "стемп готовности: $STAMP_NAME ($PREPARED_AT)"

# --- 6. permissions as in the image: directories 0555, files 0444 -------------
# COPY in the Dockerfile preserves the mode from the context, so a separate RUN chmod is not needed.
find "$STAGING_DIR" -type d -exec chmod 0555 {} +
find "$STAGING_DIR" -type f -exec chmod 0444 {} +
log "права выставлены: каталоги 0555, файлы 0444"

# --- 7. rename is the last operation ------------------------------------------
# The context directory appears already complete: an interrupted preparation leaves context.tmp,
# which the next run deletes, and an image cannot be built from half a context.
[ ! -e "$CONTEXT_DIR" ] || {
  echo "ОШИБКА: $CONTEXT_DIR появился во время подготовки — параллельный запуск prepare.sh?" >&2
  exit 1
}
mv "$STAGING_DIR" "$CONTEXT_DIR"
log "контекст готов: $CONTEXT_DIR, $(du -sh "$CONTEXT_DIR" | cut -f1), файлов $(find "$CONTEXT_DIR" -type f | wc -l)"
