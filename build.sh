#!/usr/bin/env bash
# Builds the overlay image: prepares the context (prepare.sh) and runs docker build.
#
# The pins (base image, image repository, base version) come from versions.env;
# the script has no defaults of its own. The provenance labels are taken from the context
# readiness stamp: the image describes exactly what it was built from.
#
#   bash overlay/build.sh                                 # tag <IMAGE_TAG_BASE>-local
#   bash overlay/build.sh 9.4.0.1-local-probe             # custom local tag
#   bash overlay/build.sh --override BASE_IMAGE=<ref>     # a different pin, locally
#   bash overlay/build.sh --release <image tag>           # release build with the release label
#   bash overlay/build.sh --help                          # help
set -euo pipefail

OVERLAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
. "$OVERLAY_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Сборка overlay-образа OnlyOffice Document Server.

  bash build.sh [<тег образа>] [--release] [--override КЛЮЧ=значение]... [--allow-no-reference]

Готовит контекст (prepare.sh), затем запускает docker build. Тег по умолчанию —
<IMAGE_TAG_BASE>-local из versions.env: локальная проверочная сборка, которую нельзя
спутать с публикуемым артефактом. Имена публикуемых даёт конвейер.

Закрепления — versions.env рядом со скриптом, и это единственный их источник: переменная
окружения с именем ключа файл не перекрывает. Осознанное отступление задаётся аргументом;
конвейер передаёт свои адреса через --override точно так же:

  --override КЛЮЧ=значение   собрать с другим закреплением; флаг повторяемый, ключ обязан
                             входить в состав versions.env. Так берут базу из своего
                             зеркала Docker Hub или называют образ адресом своего реестра:

    bash build.sh --override BASE_IMAGE=mirror.example.com/onlyoffice/documentserver:9.4.0.1@sha256:<digest>
    bash build.sh --override IMAGE_REPO=registry.example.com/documentserver-overlay

  --allow-no-reference       пропустить сверку api.js.tpl, когда эталона на машине нет;
                             флаг уходит в prepare.sh

  --release                  сборка выпуска. До подготовки контекста проверяет SOURCE_TAG
                             (тег вида v9.4.0.129-b24.N) и SOURCE_URL (https://, не заглушка
                             .invalid, оканчивается на /<SOURCE_TAG>); после неё — что
                             контекст собран с тега SOURCE_TAG и что окно «О программе»
                             каждого редактора несёт адрес и номер выпуска (SOURCE_TAG без v).
                             Образ получает метку overlay.release=<SOURCE_TAG>; без режима
                             выпуска этой метки у образа нет.

Адрес образа в закреплениях обязан вести в реестр, разрешённый для своего ключа
(REGISTRY_ALLOWED_BY_KEY в lib.sh: BASE_IMAGE и NODE_IMAGE — Docker Hub, IMAGE_REPO —
localhost); значение, заданное аргументом --override, от этой проверки освобождено.

Переменные окружения (пути и метки, а не закрепления):
  IMAGE_TAG        тег образа, если он не задан аргументом (аргумент важнее)
  OVERLAY_COMMIT   SHA коммита overlay для метки revision; в конвейере — CI_COMMIT_SHA
  FORK_DIR         корень форка для путей по умолчанию (по умолчанию — каталог над overlay)
  WEBAPPS_DIR, SDKJS_DIR, SDKJS_FORMS_DIR, BUILD_TOOLS_DIR, REFERENCE_TPL, CONTEXT_DIR
                   каталоги источников, эталон и контекст — см. prepare.sh
  SOURCES_DIR      каталог .sdk-minify от build-static.sh (по умолчанию — FORK_DIR)
USAGE
}

# Help, argument parsing, and tag validation come before prepare.sh: an argument error must not
# cost minutes of context preparation. Overrides must be parsed before the pins file is
# read, and they are passed to prepare.sh as the same arguments: it is a separate
# process and reads the file itself.
PREPARE_ARGS=()
IMAGE_TAG_ARG=''
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
        echo "  справка: bash build.sh --help" >&2
        exit 1
      }
      add_version_override "$2"
      PREPARE_ARGS+=(--override "$2")
      shift 2
      ;;
    --allow-no-reference)
      PREPARE_ARGS+=(--allow-no-reference)
      shift
      ;;
    -*)
      echo "ОШИБКА: неизвестный аргумент '$1'" >&2
      echo "  справка: bash build.sh --help" >&2
      exit 1
      ;;
    *)
      [ -z "$IMAGE_TAG_ARG" ] || {
        echo "ОШИБКА: тег образа задан дважды: '$IMAGE_TAG_ARG' и '$1'" >&2
        echo "  справка: bash build.sh --help" >&2
        exit 1
      }
      IMAGE_TAG_ARG="$1"
      shift
      ;;
  esac
done

read_versions "$OVERLAY_DIR"
require_keys "$OVERLAY_DIR/versions.env" '' BASE_IMAGE IMAGE_REPO IMAGE_TAG_BASE
# A release build checks the source URL and the release number before context preparation and docker:
# an image without them cannot name the sources of its release in the "About" window.
if [ "$RELEASE" = 1 ]; then
  check_release_inputs || exit 1
fi

IMAGE_TAG="${IMAGE_TAG_ARG:-${IMAGE_TAG:-$IMAGE_TAG_BASE-local}}"
# The tag goes into the image name and the version label, so its format is checked by docker's rules:
# otherwise the refusal comes from docker build, after the context has already been prepared.
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo "ОШИБКА: тег образа '$IMAGE_TAG' не по формату docker" >&2
  echo "  ожидалось: буква или цифра, далее буквы, цифры, точка, дефис, подчёркивание" >&2
  echo "  справка: bash build.sh --help" >&2
  exit 1
}
IMAGE="$IMAGE_REPO:$IMAGE_TAG"

# The base digest goes into a separate label, so it is extracted from the reference. A reference without
# a digest yields no pin; this happens when BASE_IMAGE is overridden by an argument and
# given as a bare tag; the label then honestly says the digest is unknown.
case "$BASE_IMAGE" in
  *@sha256:*) BASE_DIGEST="sha256:${BASE_IMAGE##*@sha256:}" ;;
  *)
    BASE_DIGEST="unknown"
    echo "ПРЕДУПРЕЖДЕНИЕ: BASE_IMAGE=$BASE_IMAGE задан без digest — база закреплена только тегом" >&2
    ;;
esac

# FORK_DIR is read from the environment and passed on by an explicit export: prepare.sh is a separate
# process, and without the export it would take its own value derived from the file
# location rather than ours. In the pipeline FORK_DIR is not set at all: the sources do not lie next to overlay,
# and they are addressed one by one (WEBAPPS_DIR, SDKJS_DIR, SDKJS_FORMS_DIR, BUILD_TOOLS_DIR).
export FORK_DIR="${FORK_DIR:-$(cd "$OVERLAY_DIR/.." && pwd)}"
export SOURCES_DIR="${SOURCES_DIR:-$FORK_DIR}"
read_sdk_minify "$SOURCES_DIR"

echo "==> контекст"
bash "$OVERLAY_DIR/prepare.sh" "${PREPARE_ARGS[@]}"

# The revision labels are taken from the stamp, not through git in the clones: a clone may have changed HEAD after
# preparation, and the label would then describe code other than what is in the context. The context directory
# is derived the same way as in prepare.sh.
CONTEXT_DIR="${CONTEXT_DIR:-$OVERLAY_DIR/context}"
# A missing stamp is not a parse failure but unconfirmed context readiness: this is how
# a context built by an old version of prepare.sh or by hand looks. An image cannot be built from it:
# there is nowhere to take the provenance labels from.
[ -f "$CONTEXT_DIR/$STAMP_NAME" ] || {
  echo "ОШИБКА: нет стемпа готовности $CONTEXT_DIR/$STAMP_NAME — готовность контекста не подтверждена" >&2
  echo "  собрать контекст заново: bash '$OVERLAY_DIR/prepare.sh'" >&2
  echo "  без стемпа неизвестно, из какого кода собрана статика, а метки образа берутся из него" >&2
  exit 1
}
read_stamp "$CONTEXT_DIR"
require_keys "$CONTEXT_DIR/$STAMP_NAME" 'STAMP_' "${STAMP_KEYS[@]}"

# The release label must describe what is in the context: the context was built from the release tag,
# and the "About" window in its static files carries the release URL and number.
LABEL_ARGS=()
if [ "$RELEASE" = 1 ]; then
  [ "$STAMP_SOURCE_TAG" = "$SOURCE_TAG" ] || {
    echo "ОШИБКА: контекст собран с тега $STAMP_SOURCE_TAG, а SOURCE_TAG выпуска — $SOURCE_TAG" >&2
    echo "  стемп: $CONTEXT_DIR/$STAMP_NAME" >&2
    exit 1
  }
  check_release_static "$CONTEXT_DIR/web-apps" "$SOURCE_URL" "$(release_version "$SOURCE_TAG")" || exit 1
  echo "==> статика выпуска проверена: адрес и номер $(release_version "$SOURCE_TAG") в окне каждого редактора"
  LABEL_ARGS+=(--label "overlay.release=$SOURCE_TAG")
fi

# The overlay revision: in the pipeline the job supplies it (the commit SHA), locally it is taken from
# its own repository, and outside a git clone (including a snapshot unpacked inside
# another repository) it stays unknown (overlay_revision).
OVERLAY_COMMIT="${OVERLAY_COMMIT:-$(overlay_revision "$OVERLAY_DIR")}"
CREATED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

echo "==> docker build $IMAGE (база $BASE_IMAGE)"
docker build \
  --file "$OVERLAY_DIR/Dockerfile" \
  --tag "$IMAGE" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --build-arg "BASE_DIGEST=$BASE_DIGEST" \
  --build-arg "IMAGE_VERSION=$IMAGE_TAG" \
  --build-arg "IMAGE_REF=$IMAGE" \
  --build-arg "OVERLAY_REVISION=$OVERLAY_COMMIT" \
  --build-arg "CREATED=$CREATED" \
  --build-arg "SOURCE_TAG=$STAMP_SOURCE_TAG" \
  --build-arg "WEB_APPS_REV=$STAMP_WEB_APPS_REV" \
  --build-arg "SDKJS_REV=$STAMP_SDKJS_REV" \
  --build-arg "SDKJS_FORMS_REV=$STAMP_SDKJS_FORMS_REV" \
  --build-arg "BUILD_TOOLS_REV=$STAMP_BUILD_TOOLS_REV" \
  --build-arg "API_TPL_SHA256=$STAMP_API_TPL_SHA256" \
  --build-arg "SDK_MINIFY=$STAMP_SDK_MINIFY" \
  --build-arg "SDK_MINIFY_TERSER=$STAMP_SDK_MINIFY_TERSER" \
  "${LABEL_ARGS[@]}" \
  "$OVERLAY_DIR"

echo
echo "==> готово"
printf 'Образ:       %s\n' "$IMAGE"
printf 'ID:          %s\n' "$(docker image inspect --format '{{.Id}}' -- "$IMAGE")"
printf 'Размер:      %s\n' "$(docker image inspect --format '{{.Size}}' -- "$IMAGE" | awk '{printf "%.2f ГБ (%d байт)", $1/1024/1024/1024, $1}')"
printf 'Контекст от: %s\n' "$STAMP_PREPARED_AT"
echo 'Метки:'
docker image inspect --format '{{range $k, $v := .Config.Labels}}{{printf "  %s = %s\n" $k $v}}{{end}}' -- "$IMAGE"
