#!/usr/bin/env bash
# Builds the Document Server JS static files from the source clones. The result is web-apps/deploy/web-apps
# and sdkjs/deploy/sdkjs: exactly the two directories from which prepare.sh makes the image context.
#
# The order of steps and the environment variables follow the standard ONLYOFFICE pipeline
# (build_tools/scripts/build_js.py, the make() function, the "builder" branch). The script has no values
# of its own for the pins: the version and build number come from versions.env.
#
# The steps run in a NODE_IMAGE container, so the engineer's machine and the pipeline use
# the same Node and npm versions, and the host needs nothing but docker. An empty NODE_IMAGE
# means "build with the host's tools".
#
# The build modifies the sources' working tree (standard behavior of the ONLYOFFICE pipeline), so
# before each rebuild the tree is restored, and the result is marked with an input fingerprint
# stamp: a repeated run on the same revisions does not rebuild the static files. In the pipeline
# there is never a stamp: it lies next to the sources, and those are cloned anew on every run.
#
#   bash overlay/build-static.sh                            # build, or skip by the stamp
#   FORCE_STATIC=1 bash …                                   # rebuild unconditionally
#   bash overlay/build-static.sh --release                  # release build with checks
#   bash overlay/build-static.sh --override NODE_IMAGE=     # build with the host's tools
#   bash overlay/build-static.sh --help                     # help
set -euo pipefail

# --- parameters ---------------------------------------------------------------
OVERLAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The fork root is needed only for the defaults: in the pipeline the sources do not lie next to
# overlay, and each directory is set by its own variable there.
FORK_DIR="${FORK_DIR:-$(cd "$OVERLAY_DIR/.." && pwd)}"

# shellcheck source=lib.sh
. "$OVERLAY_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Сборка JS-статики OnlyOffice Document Server из клонов-источников.

  bash build-static.sh [--release] [--override КЛЮЧ=значение]...

Результат — web-apps/deploy/web-apps и sdkjs/deploy/sdkjs, вход для prepare.sh.

  --release                  сборка выпуска. До проверок каталогов и запуска docker
                             проверяет SOURCE_TAG (тег вида v9.4.0.129-b24.N) и SOURCE_URL
                             (https://, не заглушка .invalid, оканчивается на /<SOURCE_TAG>);
                             после сборки — и при пропуске по стемпу — что окно «О программе»
                             каждого редактора в статике несёт этот адрес и номер выпуска
                             (SOURCE_TAG без v). Любое несоответствие — отказ.

Адрес исходников и номер выпуска уходят в сборку web-apps переменными SOURCE_URL и
RELEASE_VERSION в любом режиме. Заглушка адреса (хост на .invalid) в статику не попадает:
вне режима выпуска окно тогда остаётся без строки исходного кода.

Закрепления — versions.env рядом со скриптом, и это единственный их источник: переменная
окружения с именем ключа файл не перекрывает. Осознанное отступление задаётся аргументом;
конвейер передаёт свои адреса через --override точно так же:

  --override КЛЮЧ=значение   собрать с другим закреплением; флаг повторяемый, ключ обязан
                             входить в состав versions.env. Пустой NODE_IMAGE переводит
                             сборку на инструменты хоста, тогда на машине нужны node, npm
                             и python3; образ Node можно взять и из своего зеркала:

    bash build-static.sh --override SDK_MINIFY=0  # отключить минификацию SDK
    bash build-static.sh --override NODE_IMAGE=
    bash build-static.sh --override NODE_IMAGE=mirror.example.com/library/node:24

Адрес образа в закреплениях обязан вести в реестр, разрешённый для своего ключа
(REGISTRY_ALLOWED_BY_KEY в lib.sh: BASE_IMAGE и NODE_IMAGE — Docker Hub, IMAGE_REPO —
localhost); значение, заданное аргументом --override, от этой проверки освобождено.

Переменные окружения (пути и режим пересборки, а не закрепления):
  FORCE_STATIC=1   пересобрать, даже если стемп совпал с отпечатком входа
  FORK_DIR         корень форка для путей по умолчанию (по умолчанию — каталог над overlay)
  WEBAPPS_DIR, SDKJS_DIR, SDKJS_FORMS_DIR
                   клоны-источники (по умолчанию — рядом, внутри FORK_DIR)
  BUILD_TOOLS_DIR  клон сборочных скриптов; нужен только ревизией, в отпечатке входа
  SOURCES_DIR      каталог, где лежит стемп .static-stamp (по умолчанию — FORK_DIR)
  CACHE_DIR        зависимости npm и кэш загрузок вне дерева источников
                   (по умолчанию — overlay/.cache)
USAGE
}

# The arguments are parsed before the pins are read: overrides must be known
# before the file is read.
RELEASE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --release)
      RELEASE=1
      shift
      ;;
    --override)
      [ $# -ge 2 ] || {
        echo "ОШИБКА: --override без значения — ожидалось КЛЮЧ=значение" >&2
        echo "  справка: bash build-static.sh --help" >&2
        exit 1
      }
      add_version_override "$2"
      shift 2
      ;;
    *)
      echo "ОШИБКА: неизвестный аргумент '$1'" >&2
      echo "  справка: bash build-static.sh --help" >&2
      exit 1
      ;;
  esac
done

# The pins are read before any checks: there is nothing to check until it is known what is pinned.
read_versions "$OVERLAY_DIR"
require_keys "$OVERLAY_DIR/versions.env" '' PRODUCT_VERSION BUILD_NUMBER
# A release build checks the source URL and the release number before anything else: without them
# the release's "About" window will not name the sources, and the failure must come before directories and docker.
if [ "$RELEASE" = 1 ]; then
  check_release_inputs || exit 1
fi
# NODE_IMAGE and NPM_REGISTRY may be empty by contract, so they do not belong in require_keys.
# They need no defaults: read_key_value_file resets the whole set of the file's keys before
# parsing, so both variables are declared, as empty, even if the key is missing from the file.

WEBAPPS_DIR="${WEBAPPS_DIR:-$FORK_DIR/web-apps}"
SDKJS_DIR="${SDKJS_DIR:-$FORK_DIR/sdkjs}"
SDKJS_FORMS_DIR="${SDKJS_FORMS_DIR:-$FORK_DIR/sdkjs-forms}"
BUILD_TOOLS_DIR="${BUILD_TOOLS_DIR:-$FORK_DIR/_ref/build_tools}"
SOURCES_DIR="${SOURCES_DIR:-$FORK_DIR}"
CACHE_DIR="${CACHE_DIR:-$OVERLAY_DIR/.cache}"
FORCE_STATIC="${FORCE_STATIC:-0}"

STAMP_FILE="$SOURCES_DIR/.static-stamp"
# The container name is needed so that an interrupted run does not leave a running build behind:
# the signal handler removes the container by name. The process ID is there so that two runs on a
# machine do not interfere with each other more than they already do with the shared working tree.
CONTAINER_NAME="oo-build-static-$$"

log() { printf '==> %s\n' "$*"; }

# --- input checks -------------------------------------------------------------
# Everything is checked before the first mutating operation: a rebuild takes 20-25 minutes, and a failure on
# a path typo must come in the first seconds.

# The version and build number are baked into the static files (the sdkjs version string, the api.js cache version),
# so the format is checked here, not only in prepare.sh: otherwise a wrong value
# would surface 20 minutes later, at the context verification.
[[ "$PRODUCT_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
  echo "ОШИБКА: PRODUCT_VERSION='$PRODUCT_VERSION' — ожидались только цифры и точки" >&2
  exit 1
}
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "ОШИБКА: BUILD_NUMBER='$BUILD_NUMBER' — ожидались только цифры" >&2
  exit 1
}

# Paths are normalized to absolute: they go to docker as mount points, and
# docker does not accept a relative path. This also rejects a nonexistent directory.
for pair in "WEBAPPS_DIR:$WEBAPPS_DIR" "SDKJS_DIR:$SDKJS_DIR" "SDKJS_FORMS_DIR:$SDKJS_FORMS_DIR" \
            "BUILD_TOOLS_DIR:$BUILD_TOOLS_DIR" "SOURCES_DIR:$SOURCES_DIR"; do
  dir_var="${pair%%:*}"
  dir_val="${pair#*:}"
  [ -d "$dir_val" ] || {
    echo "ОШИБКА: $dir_var=$dir_val — каталога нет" >&2
    echo "  клоны-источники разворачиваются командами из README, раздел \"Clones\"" >&2
    exit 1
  }
  printf -v "$dir_var" '%s' "$(cd "$dir_val" && pwd)"
done

# The clone revisions are half of the input fingerprint, so each source must be a git clone.
# The build_tools revision is part of the fingerprint, although the static build itself does not touch this clone:
# its python code is executed by prepare.sh, and a revision change changes what goes into the image.
for pair in "WEBAPPS_REV:$WEBAPPS_DIR" "SDKJS_REV:$SDKJS_DIR" \
            "SDKJS_FORMS_REV:$SDKJS_FORMS_DIR" "BUILD_TOOLS_REV_ACTUAL:$BUILD_TOOLS_DIR"; do
  rev_var="${pair%%:*}"
  repo_dir="${pair#*:}"
  repo_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
  [ -n "$repo_head" ] || {
    echo "ОШИБКА: $repo_dir не git-клон — ревизию для отпечатка входа взять неоткуда" >&2
    exit 1
  }
  printf -v "$rev_var" '%s' "$repo_head"
done

# The source tag is the same pin and the same check as in prepare.sh, but performed before
# the build: a clone left on a different tag would otherwise be rejected only in prepare.sh, that is,
# after 20-25 minutes of rebuilding. build_tools is intentionally not in this check: it has no tags for the needed
# release, it is pinned by revision and checked in prepare.sh.
[ -n "$SOURCE_TAG" ] || {
  echo "ОШИБКА: SOURCE_TAG пуст — тег источников сверить не с чем" >&2
  echo "  состав закреплений — README, раздел \"Build pins\"" >&2
  exit 1
}
for repo_dir in "$WEBAPPS_DIR" "$SDKJS_DIR" "$SDKJS_FORMS_DIR"; do
  # The list of tags is taken into a variable, the comparison is without a pipe: grep -q closes the pipe
  # after the first match, and with pipefail a successful check would fail with SIGPIPE.
  repo_tags=$(git -C "$repo_dir" tag --points-at HEAD)
  grep -qxF "$SOURCE_TAG" <<<"$repo_tags" || {
    echo "ОШИБКА: $(basename "$repo_dir") не на теге $SOURCE_TAG" >&2
    echo "  каталог:      $repo_dir" >&2
    echo "  теги на HEAD: ${repo_tags//$'\n'/ }" >&2
    echo "  нужный тег:   git -C '$repo_dir' checkout $SOURCE_TAG" >&2
    echo "  осознанная сборка с другого тега: --override SOURCE_TAG=<тег>" >&2
    exit 1
  }
done

# sdkjs/build/build.py:263-266 resolves --addon=sdkjs-forms as <sdkjs root>/../sdkjs-forms.
# A directory set bypassing this rule will not break the build: it will simply build sdkjs without the
# forms addon, and the discrepancy with the image would surface only at the api.js.tpl verification.
sdkjs_forms_expected="$(cd "$SDKJS_DIR/.." && pwd)/sdkjs-forms"
[ "$SDKJS_FORMS_DIR" = "$sdkjs_forms_expected" ] || {
  echo "ОШИБКА: аддон forms должен лежать рядом с sdkjs под именем sdkjs-forms" >&2
  echo "  ожидалось: $sdkjs_forms_expected" >&2
  echo "  получено:  $SDKJS_FORMS_DIR" >&2
  echo "  так его ищет sdkjs/build/build.py — путь из --addon разрешается относительно sdkjs/.." >&2
  exit 1
}

# The pipeline entry points. Without them the build would fail only after the tree is restored, that is,
# destroying the result of the previous run.
for f in "$WEBAPPS_DIR/translation/merge_and_check.py" "$WEBAPPS_DIR/build/Gruntfile.js" \
         "$SDKJS_DIR/build/build.py"; do
  [ -f "$f" ] || {
    echo "ОШИБКА: нет $f — на этом теге источников такого шага сборки нет" >&2
    exit 1
  }
done

if [ -n "$NODE_IMAGE" ]; then
  command -v docker >/dev/null || {
    echo "ОШИБКА: нет docker, а сборка идёт в контейнере NODE_IMAGE=$NODE_IMAGE" >&2
    echo "  собрать инструментами хоста: bash build-static.sh --override NODE_IMAGE=" >&2
    exit 1
  }
else
  for tool in node npm python3; do
    command -v "$tool" >/dev/null || {
      echo "ОШИБКА: нет $tool, а NODE_IMAGE пуст — собирать нечем" >&2
      echo "  версии инструментов — README, раздел \"Environment requirements\"" >&2
      echo "  собрать в контейнере: уберите --override NODE_IMAGE= из вызова" >&2
      exit 1
    }
  done
fi

# --- input fingerprint --------------------------------------------------------
# The fingerprint includes the pins as a whole (the file's sum), the revisions of the four clones, and the overrides
# given as arguments: this is everything the build result is made of. The fingerprint does not see the state of the
# working tree: what protects against foreign edits in the tree is not it but
# the restore before a rebuild.
#
# Overrides are not visible in the file's sum: they are applied over what was read, and some of
# them directly change the result: PRODUCT_VERSION and BUILD_NUMBER are baked into the static files. Without
# them a build with --override would pass for a standard one, and the next standard run would skip
# the rebuild based on someone else's stamp. The component is added only for a non-empty list: otherwise
# stamps written before this change would stop matching for no reason. The order of the
# arguments does not affect the fingerprint: the pairs are sorted.
versions_sum=$(sha256sum "$OVERLAY_DIR/versions.env" | cut -d' ' -f1)
WANT="$versions_sum $WEBAPPS_REV $SDKJS_REV $SDKJS_FORMS_REV $BUILD_TOOLS_REV_ACTUAL"
# A change of the minification mode or script changes the result; the stamp must see it.
minifier_sum=$(sha256sum "$OVERLAY_DIR/tools/sdk-minify.cjs" | cut -d' ' -f1)
WANT="$WANT sdk-minify=$SDK_MINIFY terser=$TERSER_VERSION minifier=$minifier_sum"
if [ "${#VERSIONS_OVERRIDES[@]}" -gt 0 ]; then
  mapfile -t overrides_sorted < <(printf '%s\n' "${VERSIONS_OVERRIDES[@]}" | LC_ALL=C sort)
  WANT="$WANT ${overrides_sorted[*]}"
fi

# In the pipeline there is no stamp by construction, not by a mode flag: it lies in SOURCES_DIR,
# and that is recreated there on every run together with the clones. So the build always runs, and
# a revision match does not pass off as a finished result something that is not on disk.
have=''
if [ -f "$STAMP_FILE" ]; then
  have=$(cat "$STAMP_FILE")
fi

# A skip is allowed only if the mode file is readable by the preparation and describes the same mode:
# a corrupted file would otherwise let the build be skipped, and the preparation would then fail.
sdk_minify_current() {
  local want="$1" version=none
  [ "$want" != 1 ] || version="$TERSER_VERSION"
  ( read_sdk_minify "$SOURCES_DIR" 2>/dev/null && [ "$SDK_MINIFY" = "$want" ] && [ "$SDK_MINIFY_TERSER" = "$version" ] )
}

if [ "$FORCE_STATIC" = 1 ]; then
  log "FORCE_STATIC=1: пересборка запрошена явно"
elif [ "$have" = "$WANT" ] && [ -d "$WEBAPPS_DIR/deploy/web-apps" ] && [ -d "$SDKJS_DIR/deploy/sdkjs" ] \
  && sdk_minify_current "$SDK_MINIFY"; then
  log "статика актуальна для $WANT, сборка пропущена"
  # Skipping by the stamp does not exempt a release from the static files check: the stamp confirms the input
  # revisions, not that the "About" window in the built files carries the release address and number.
  if [ "$RELEASE" = 1 ]; then
    check_release_static "$WEBAPPS_DIR/deploy/web-apps" "$SOURCE_URL" "$(release_version "$SOURCE_TAG")" || exit 1
    log "статика выпуска проверена: адрес и номер $(release_version "$SOURCE_TAG") в окне каждого редактора"
  fi
  exit 0
fi

# --- build environment --------------------------------------------------------
# The set of variables is from build_js.py: COMPANY_NAME in uppercase (otherwise sdk-all-min.js diverges
# from the official static files), the version and build number from the pins, NODE_ENV=production.
# APP_CUSTOMER_NAME=ONLYOFFICE keeps api.js byte-identical to the official one: since 2026-10-15 the grunt
# default in the fork's web-apps is a different product name, and without the variable api.js diverges from the reference
# at the verification.
# SOURCE_URL and RELEASE_VERSION are the source address and release number for the "About" window;
# web-apps substitutes them during the build. A placeholder address is passed as an empty value (build_source_url).
# The npm download cache is set explicitly and lives outside the sources tree: the tree is restored
# before each rebuild, and in the pipeline it is a fresh clone anyway.
STEP_ENV=(
  COMPANY_NAME=ONLYOFFICE
  APP_CUSTOMER_NAME=ONLYOFFICE
  "PRODUCT_VERSION=$PRODUCT_VERSION"
  "BUILD_NUMBER=$BUILD_NUMBER"
  "SOURCE_URL=$(build_source_url)"
  "RELEASE_VERSION=$(release_version "$SOURCE_TAG")"
  NODE_ENV=production
  "npm_config_cache=$CACHE_DIR/npm"
)
# An empty NPM_REGISTRY means "the default registry of the Node image", so the variable is then not
# set at all: npm_config_registry with an empty value does not select a registry but breaks.
[ -z "$NPM_REGISTRY" ] || STEP_ENV+=("npm_config_registry=$NPM_REGISTRY")

mkdir -p "$CACHE_DIR/npm"

DOCKER_ARGS=()
if [ -n "$NODE_IMAGE" ]; then
  # The dependency directories live in CACHE_DIR and are put into the tree by mounting, not by
  # symlinks: npm and webpack see ordinary directories, and nothing appears in the sources tree
  # itself that would outlive its recreation. In the pipeline the tree is a fresh clone on every run,
  # and this is the only way not to install 513 MB of dependencies anew.
  mkdir -p "$CACHE_DIR/home" \
           "$CACHE_DIR/node_modules/web-apps-build" \
           "$CACHE_DIR/node_modules/framework7-react"
  # The home directory is moved into CACHE_DIR: the container runs as the host's uid, while the image's home
  # directory belongs to root, so npm would fail on its first write there.
  STEP_ENV+=("HOME=$CACHE_DIR/home")

  # Each directory is mounted at its own host path: the build scripts move between
  # clones by relative paths (sdkjs -> ../sdkjs-forms), and matching paths inside and
  # outside the container preserves these links without a single fix.
  DOCKER_ARGS+=(
    --volume "$WEBAPPS_DIR:$WEBAPPS_DIR"
    --volume "$SDKJS_DIR:$SDKJS_DIR"
    --volume "$SDKJS_FORMS_DIR:$SDKJS_FORMS_DIR"
    --volume "$CACHE_DIR:$CACHE_DIR"
    --volume "$OVERLAY_DIR/tools:$OVERLAY_DIR/tools:ro"
    --volume "$CACHE_DIR/node_modules/web-apps-build:$WEBAPPS_DIR/build/node_modules"
    --volume "$CACHE_DIR/node_modules/framework7-react:$WEBAPPS_DIR/vendor/framework7-react/node_modules"
  )
  for pair in "${STEP_ENV[@]}"; do
    DOCKER_ARGS+=(--env "$pair")
  done
fi

# An interrupted run must not leave a running build behind: docker does not remove the container when
# the client that started it is killed. The handler does not touch the stamp: it is deleted before the first
# mutating operation, and by the time of the signal it is either already deleted or still describes the untouched
# result of the previous run.
minify_output=''
# The handler must write to the original stderr even if the step's output is redirected to a file.
exec 3>&2
trap '[ -z "$minify_output" ] || rm -f "$minify_output"' EXIT

on_signal() {
  trap - INT TERM
  {
    [ -z "$minify_output" ] || cat "$minify_output" || true
    echo
    echo "ОШИБКА: сборка статики прервана — стемп не записан, следующий запуск соберёт заново"
  } >&3
  [ -z "$NODE_IMAGE" ] || docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
  exit 130
}
trap on_signal INT TERM

# Runs one pipeline step: in a NODE_IMAGE container or with the host's tools.
#   $1 — the step's working directory, the rest — the command with arguments
# One branch serves both paths, because only the way of launching and the location of the dependencies differ;
# the commands themselves, their order, and the environment are shared by the host and the container.
run_step() {
  local workdir="$1"
  shift
  if [ -z "$NODE_IMAGE" ]; then
    ( cd "$workdir" && env "${STEP_ENV[@]}" "$@" 3>&- )
    return
  fi
  # The container is started in the background and awaited through wait: while bash waits for a command in the
  # foreground, the signal handler is deferred until it finishes, and a cancelled job would leave
  # the build running for another ten minutes. Waiting through wait is interrupted by the signal immediately.
  # run_step is called in the current shell; the output is redirected to a file when needed.
  # --init: without it the stop signal does not reach the child processes of the build (grunt
  # starts webpack).
  # The separator before the image: the pin value must not be parsed as a docker
  # option, even if it starts with a hyphen.
  docker run --rm --init \
    --name "$CONTAINER_NAME" \
    --user "$(id -u):$(id -g)" \
    --workdir "$workdir" \
    "${DOCKER_ARGS[@]}" \
    -- "$NODE_IMAGE" "$@" 3>&- &
  wait $!
}

# --- 1. the stamp is deleted before the first mutating operation ---------------
# An interrupted build must not look fresh: the stamp confirms a result, not an intention.
# The mode file too: otherwise the preparation would sign the image with the mode of the previous build.
rm -f "$STAMP_FILE" "$STAMP_FILE.tmp" "$SOURCES_DIR/.sdk-minify" "$SOURCES_DIR/.sdk-minify.tmp"

# --- 2. restoring the working tree ---------------------------------------------
# The build modifies tracked source files (merge_and_check.py tops up the dictionaries, the
# increment-build task writes build+1 into the component descriptions) and leaves untracked webpack
# output. A rebuild on top of such a tree gives a different result than on a fresh clone,
# so the tree is returned to the state of the tag. The dependency directories are excluded: otherwise
# reuse would be pointless, and they are 513 MB to install.
#
# There is no separate branch for the pipeline here: the clones are fresh on every run there, and both commands
# run idle in milliseconds. A branch by a CI execution flag would be
# behavior that depends on a run variable, and no such dependency is left in the scripts.
for dir in "$WEBAPPS_DIR" "$SDKJS_DIR" "$SDKJS_FORMS_DIR"; do
  git -C "$dir" checkout -- .
  git -C "$dir" clean -fd -e node_modules
done
log "рабочее дерево источников восстановлено"

# --- 3. sdkjs (build_js.py:148-150, build_sdk_builder) -------------------------
# At this tag sdkjs is built by concatenation in python: neither grunt, nor the closure compiler, nor
# Java are needed, and the --minimize and --map flags are accepted for compatibility and declared no-op.
build_sdkjs() {
  local started=$SECONDS
  log "sdkjs: python3 build.py --beta=false --minimize --addon=sdkjs-forms --map"
  run_step "$SDKJS_DIR/build" python3 build.py --beta=false --minimize --addon=sdkjs-forms --map
  log "sdkjs собран за $((SECONDS - started)) с"
}

# --- 4. web-apps (build_js.py:49 and 131-134, build_interface) -----------------
# npm install, not npm ci: this is what the standard pipeline does (build_js.py:107-111), and only this way
# are the already installed dependencies reused: npm ci wipes the directory entirely before
# installing. The set is still taken from package-lock.json: the file is tracked in the repository
# and consistent with package.json, and the sources tree is restored before each rebuild.
build_webapps() {
  local started=$SECONDS
  log "web-apps: merge_and_check.py (словари локализации)"
  run_step "$WEBAPPS_DIR/translation" python3 merge_and_check.py

  log "web-apps: npm install"
  run_step "$WEBAPPS_DIR/build" npm install

  # Two full runs are not redundant. The formats sprite
  # apps/common/main/resources/img/doc-formats/formats@2.5x.svg is generated into the sources by the prebuild-icons-sprite task
  # and laid out into deploy by the svgmin task of the common component,
  # which runs earlier: on a clean clone the sprite gets into the result only on the second run.
  # Rebuilding the common component alone instead is not possible: the placeholder substitution in the
  # shared files is done by the tasks of the editor components.
  local pass
  for pass in 1 2; do
    log "web-apps: npx grunt --force (проход $pass из 2)"
    run_step "$WEBAPPS_DIR/build" npx grunt --force
  done
  log "web-apps собран за $((SECONDS - started)) с"
}

build_sdkjs
build_webapps

# Terser is taken from the web-apps dependencies after npm install; this step runs before the pre-compression in the image.
SDK_MINIFY_TERSER=none
if [ "$SDK_MINIFY" = 1 ]; then
  minify_output=$(mktemp)
  minify_status=0
  run_step "$SDKJS_DIR/build" node "$OVERLAY_DIR/tools/sdk-minify.cjs" \
    "$SDKJS_DIR/deploy/sdkjs" "$WEBAPPS_DIR/build" "$TERSER_VERSION" > "$minify_output" 2>&1 || minify_status=$?
  cat "$minify_output"
  [ "$minify_status" = 0 ] || exit "$minify_status"
  SDK_MINIFY_TERSER=$(sed -n 's/^sdk-minify: terser=//p' "$minify_output")
  rm -f "$minify_output"
  minify_output=''
  [[ "$SDK_MINIFY_TERSER" =~ ^5\.[0-9]+\.[0-9]+$ ]] && [ "$SDK_MINIFY_TERSER" = "$TERSER_VERSION" ] || {
    echo "ОШИБКА: sdk-minify не сообщил закреплённую версию Terser $TERSER_VERSION" >&2
    exit 1
  }
  log "sdkjs: minify (Terser $SDK_MINIFY_TERSER)"
else
  log "sdkjs: минификация отключена"
fi

# --- 5. result check -----------------------------------------------------------
# grunt is run with --force, that is, it finishes successfully even if a task failed. Hence
# the check is not of the return code but of the result itself: the two build directories, the client-side entry
# point, and the formats sprite, the only file proving that the second run worked.
for f in "$SDKJS_DIR/deploy/sdkjs/word/sdk-all-min.js" \
         "$WEBAPPS_DIR/deploy/web-apps/apps/api/documents/api.js" \
         "$WEBAPPS_DIR/deploy/web-apps/apps/common/main/resources/img/doc-formats/formats@2.5x.svg"; do
  [ -s "$f" ] || {
    echo "ОШИБКА: сборка закончилась, но нет файла $f" >&2
    echo "  grunt работает с --force и не падает на упавшей задаче — ищите её в журнале выше" >&2
    exit 1
  }
done

# A release build also checks what it exists for: the "About" window of each editor
# carries the source address and the release number, and there are no unsubstituted placeholders. The stamp is not
# written on failure: the static files are not suitable for a release.
if [ "$RELEASE" = 1 ]; then
  check_release_static "$WEBAPPS_DIR/deploy/web-apps" "$SOURCE_URL" "$(release_version "$SOURCE_TAG")" || exit 1
  log "статика выпуска проверена: адрес и номер $(release_version "$SOURCE_TAG") в окне каждого редактора"
fi

# --- 6. the stamp is written last ----------------------------------------------
# The mode describes the already finished static files; the stamp must not be published before this file.
printf 'SDK_MINIFY=%s\nSDK_MINIFY_TERSER=%s\n' "$SDK_MINIFY" "$SDK_MINIFY_TERSER" > "$SOURCES_DIR/.sdk-minify.tmp"
mv "$SOURCES_DIR/.sdk-minify.tmp" "$SOURCES_DIR/.sdk-minify"

# The write is atomic: the stamp either describes a finished result or does not exist.
printf '%s\n' "$WANT" > "$STAMP_FILE.tmp"
mv "$STAMP_FILE.tmp" "$STAMP_FILE"

log "статика собрана: $(du -sh "$WEBAPPS_DIR/deploy/web-apps" | cut -f1) web-apps, $(du -sh "$SDKJS_DIR/deploy/sdkjs" | cut -f1) sdkjs"
log "стемп: $STAMP_FILE ($WANT)"
