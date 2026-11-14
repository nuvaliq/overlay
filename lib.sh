#!/usr/bin/env bash
# Common functions of the overlay scripts: reading KEY=value files and checks for the
# release build.
#
# There are three such files, and they share one format:
#   versions.env          — build pins (the only place in the repository);
#   .sdk-minify           — mode and tool version of the finished static files;
#   context/.overlay-stamp — context readiness stamp, from which the image labels are taken.
#
# Loaded with `source` from prepare.sh and build.sh. It runs no code of its own when
# sourced: it only declares functions and the set of files.

# The set of keys of versions.env. The list is shared by all scripts rather than one per script: there is one file,
# and a key needed only by a neighboring script must not be a parse error.
VERSIONS_KEYS=(
  BASE_IMAGE
  IMAGE_TAG_BASE
  SOURCE_TAG
  SOURCE_URL
  BUILD_TOOLS_REV
  PRODUCT_VERSION
  BUILD_NUMBER
  SDK_MINIFY
  TERSER_VERSION
  EXPECTED_API_TPL_SHA256
  IMAGE_REPO
  NODE_IMAGE
  NPM_REGISTRY
  BUILD_TOOLS_URL
  WEB_APPS_URL
  SDKJS_URL
  SDKJS_FORMS_URL
)

# The set of keys of the context readiness stamp. The key order is the line order in the file: prepare.sh
# uses it when writing, so there is one list here for both reading and writing.
STAMP_KEYS=(
  SOURCE_TAG
  WEB_APPS_REV
  SDKJS_REV
  SDKJS_FORMS_REV
  BUILD_TOOLS_REV
  API_TPL_SHA256
  SDK_MINIFY
  SDK_MINIFY_TERSER
  PREPARED_AT
)

# The stamp name inside the context directory. It starts with a dot and lies in the context root,
# so it does not get into the image: the Dockerfile copies only context/sdkjs and context/web-apps.
STAMP_NAME='.overlay-stamp'

# The allowed registry for each pin that addresses an image. The pin's value must
# lead to it: this address defines the images whose code runs on the build machine and the place
# the built image is sent to. The host is derived from the reference by docker's rules (registry_host).
# The table is a repository constant: it is changed by a commit, not by a run.
declare -A REGISTRY_ALLOWED_BY_KEY=([BASE_IMAGE]=docker.io [NODE_IMAGE]=docker.io [IMAGE_REPO]=localhost)

# Pins whose value is an image reference in a registry.
REGISTRY_REF_KEYS=(
  IMAGE_REPO
  BASE_IMAGE
  NODE_IMAGE
)

# Pin overrides given by the --override KEY=value argument. The pairs
# are accumulated here by argument parsing and applied over the file in read_versions.
VERSIONS_OVERRIDES=()

# Reads a KEY=value file and assigns the values to shell variables.
#   $1 — path to the file
#   $2 — prefix of the variable names ('' — no prefix)
#   the rest — allowed keys
#
# The file is not executed: lines are parsed one by one, and the value goes into the variable through
# printf -v, bypassing shell expansion. Otherwise a pin like $(...) or `...` would become
# executable code, and the pins file is edited both in the pipeline and by hand.
#
# The value from the file is always assigned: an environment variable named like a key does not
# override the file. Otherwise whoever launches the build would choose the images whose code runs on the build machine and
# the registry the built image is sent to together with the login credentials, that is,
# the pins would stop being pins. A deliberate override is only the explicit
# --override KEY=value argument (add_version_override below): this is how both a local build and a
# pipeline with its own addresses deviate from the file visibly, with separate arguments.
read_key_value_file() {
  local file="$1" prefix="$2"
  shift 2
  local allowed=" $* "
  local lineno=0 line key value name

  [ -f "$file" ] || {
    echo "ОШИБКА: нет файла $file — брать значения негде" >&2
    return 1
  }

  # All allowed keys are reset before parsing: a key that is absent from the file must yield
  # an empty value rather than inherit an environment variable of the same name. Otherwise a line removed from
  # the file would give the environment influence over the pin again, and a missing value
  # is caught by require_keys, against the file rather than whatever happened to be in the environment.
  for key in "$@"; do
    printf -v "$prefix$key" '%s' ''
  done

  # IFS= and -r: the value is taken verbatim, with no whitespace trimming or backslash expansion.
  # `|| [ -n "$line" ]` so as not to lose the last line of a file without a trailing newline.
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Empty lines and comments.
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi

    # An empty value is allowed (KEY=), although the pin format requires a non-empty one:
    # NPM_REGISTRY is empty by contract and means "the default registry of the Node image".
    # There are no spaces in the value on purpose: values go into docker build arguments and into the
    # sed expression, and there are no quotes in the file, so there would be nothing to separate them with.
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([^[:space:]]*)$ ]] || {
      echo "ОШИБКА: $file:$lineno — строка не по формату КЛЮЧ=значение" >&2
      echo "  строка:   $line" >&2
      echo "  ожидался КЛЮЧ из заглавных букв, цифр и подчёркиваний, знак =, значение без пробелов" >&2
      return 1
    }
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    case "$allowed" in
      *" $key "*) ;;
      *)
        echo "ОШИБКА: $file:$lineno — неизвестный ключ $key" >&2
        echo "  допустимые ключи: $*" >&2
        echo "  новый ключ сначала заводится в составе файла (lib.sh), иначе его никто не прочитает" >&2
        return 1
        ;;
    esac

    name="$prefix$key"
    printf -v "$name" '%s' "$value"
  done < "$file"
}

# Accepts one value of the --override argument and remembers it until the file is read.
#   $1 — a KEY=value pair
#
# The key must belong to the set of the pins file, and the value must follow the same grammar as in
# the file: without spaces, because values go into docker arguments and into the sed expression, and
# neither the file nor the argument carries quotes.
add_version_override() {
  local pair="$1" key value allowed=" ${VERSIONS_KEYS[*]} "

  [[ "$pair" =~ ^([A-Z][A-Z0-9_]*)=([^[:space:]]*)$ ]] || {
    echo "ОШИБКА: --override '$pair' не по формату КЛЮЧ=значение" >&2
    echo "  ожидался КЛЮЧ из заглавных букв, цифр и подчёркиваний, знак =, значение без пробелов" >&2
    return 1
  }
  key="${BASH_REMATCH[1]}"
  value="${BASH_REMATCH[2]}"

  case "$allowed" in
    *" $key "*) ;;
    *)
      echo "ОШИБКА: --override $key — такого закрепления нет" >&2
      echo "  допустимые ключи: ${VERSIONS_KEYS[*]}" >&2
      return 1
      ;;
  esac

  VERSIONS_OVERRIDES+=("$key=$value")
}

# Applies the accumulated overrides over the values read from the file. Each one is printed
# as a warning, with the key only: what is built this way differs from what is built from the file, and this
# must be visible in the log.
apply_version_overrides() {
  local pair key value

  for pair in "${VERSIONS_OVERRIDES[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    printf -v "$key" '%s' "$value"
    echo "ПРЕДУПРЕЖДЕНИЕ: закрепление $key переопределено аргументом --override" >&2
  done
}

# Prints the registry host of an image reference by docker's rules.
#   $1 — image reference
#
# The first segment before the slash is a registry only if it contains a dot or a colon or
# is localhost. Otherwise it is a Docker Hub namespace (onlyoffice/documentserver), and the
# registry is docker.io; a reference without a slash (node:24) is also Docker Hub.
registry_host() {
  local ref="$1" first

  case "$ref" in
    */*) first="${ref%%/*}" ;;
    *)
      echo docker.io
      return 0
      ;;
  esac
  case "$first" in
    *.*|*:*|localhost) echo "$first" ;;
    *) echo docker.io ;;
  esac
}

# Prints an image reference without the registry host.
#   $1 — image reference
#
# A single-segment name on Docker Hub gets the library/ namespace, as docker expands it:
# node:24 and docker.io/node:24 both give library/node:24. This way the reference can be moved to a
# Docker Hub mirror by prepending its address.
registry_path() {
  local ref="$1" host path

  host="$(registry_host "$ref")"
  case "$ref" in
    "$host"/*) path="${ref#*/}" ;;
    *) path="$ref" ;;
  esac
  if [ "$host" = docker.io ]; then
    case "$path" in
      */*) ;;
      *) path="library/$path" ;;
    esac
  fi
  echo "$path"
}

# Fails if an image reference leads to a registry other than the one allowed for its key.
#   $1 — pins file (for the message)
#
# The allowed registry is set for each key separately (REGISTRY_ALLOWED_BY_KEY): the base
# image and the Node image come from Docker Hub, while the built image is named only with a local
# name and is not sent anywhere until explicitly overridden. An empty value is skipped:
# NODE_IMAGE uses it to disable building in a container.
check_registry_hosts() {
  local file="$1" key value host want bad=()

  for key in "${REGISTRY_REF_KEYS[@]}"; do
    value="${!key:-}"
    [ -n "$value" ] || continue
    host="$(registry_host "$value")"
    want="${REGISTRY_ALLOWED_BY_KEY[$key]:-}"
    [ -n "$want" ] && [ "$host" = "$want" ] || bad+=("$key=$value (разрешён ${want:-ни один реестр})")
  done

  [ ${#bad[@]} -eq 0 ] || {
    echo "ОШИБКА: в $file адрес образа ведёт в неразрешённый реестр: ${bad[*]}" >&2
    echo "  разрешённый реестр по ключам — REGISTRY_ALLOWED_BY_KEY в lib.sh" >&2
    echo "  этим адресом заданы образы, чей код исполняется на машине сборки, и место, куда уходит собранный образ" >&2
    echo "  сборка с другого адреса — осознанное решение и задаётся аргументом --override КЛЮЧ=значение" >&2
    return 1
  }
}

# Checks the registry host of each reference against a pinned SHA-256 fingerprint.
#   $1 — expected fingerprint: 64 lowercase hexadecimal characters
#   the rest — image references
#
# The fingerprint is the sha256 of the host (registry_host) without a trailing newline. This way a build that enters
# its own registry pins it by a commit without writing the address itself: a value substituted at
# run time will not match the fingerprint. The function prints neither hosts nor fingerprints: the
# message has only the reference number. A failure is an empty or malformed fingerprint, no
# references, an empty reference, or a mismatch.
check_registry_fingerprint() {
  local expected="${1:-}" ref sum n=0

  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    echo "ОШИБКА: отпечаток хоста реестра пуст или не из 64 шестнадцатеричных знаков в нижнем регистре" >&2
    return 1
  }
  shift
  [ $# -gt 0 ] || {
    echo "ОШИБКА: сверка отпечатка хоста реестра без ссылок на образы — сверять нечего" >&2
    return 1
  }
  for ref in "$@"; do
    n=$((n + 1))
    [ -n "$ref" ] || {
      echo "ОШИБКА: ссылка на образ №$n пуста — хост реестра сверить не с чем" >&2
      return 1
    }
    sum="$(printf '%s' "$(registry_host "$ref")" | sha256sum)"
    sum="${sum%% *}"
    [ "${sum,,}" = "$expected" ] || {
      echo "ОШИБКА: хост реестра ссылки на образ №$n не совпал с закреплённым отпечатком" >&2
      return 1
    }
  done
}

# Reads the pins from the overlay directory's versions.env. The file is the only source:
# an environment variable named like a key does not change the value, and a local override
# comes as an explicit --override argument, parsed before this call.
read_versions() {
  read_key_value_file "$1/versions.env" '' "${VERSIONS_KEYS[@]}" || return 1
  # Registries are checked on the file's values and before the overrides are applied: the file must
  # lead to an allowed registry always and everywhere, while --override is a deliberate decision
  # of whoever launches the build. A build that pushes the image to its own registry checks its host separately
  # (check_registry_fingerprint).
  check_registry_hosts "$1/versions.env" || return 1
  apply_version_overrides || return 1
  require_keys "$1/versions.env" '' SDK_MINIFY TERSER_VERSION || return 1
  [[ "$SDK_MINIFY" =~ ^[01]$ ]] || {
    echo "ОШИБКА: SDK_MINIFY — ожидалось 0 или 1" >&2
    return 1
  }
  [[ "$TERSER_VERSION" =~ ^5\.[0-9]+\.[0-9]+$ ]] || {
    echo "ОШИБКА: TERSER_VERSION — ожидалась версия Terser 5.x вида 5.<число>.<число>" >&2
    return 1
  }
}

# Reads the context readiness stamp into variables with the STAMP_ prefix. The prefix is needed so that
# values from the context are not confused with the pins: SOURCE_TAG and BUILD_TOOLS_REV exist in
# both places, and the image labels must describe precisely the built context.
read_stamp() {
  read_key_value_file "$1/$STAMP_NAME" 'STAMP_' "${STAMP_KEYS[@]}"
}

# The mode and version are taken only from the result of the static build, not from the environment.
read_sdk_minify() {
  local file="$1/.sdk-minify" expected_mode="$SDK_MINIFY" expected_terser=none
  [ "$expected_mode" != 1 ] || expected_terser="$TERSER_VERSION"
  [ -f "$file" ] || {
    echo "ОШИБКА: нет файла $file — сначала выполни build-static.sh с тем же SOURCES_DIR" >&2
    return 1
  }
  read_key_value_file "$file" '' SDK_MINIFY SDK_MINIFY_TERSER || return 1
  require_keys "$file" '' SDK_MINIFY SDK_MINIFY_TERSER || return 1
  if [ "$SDK_MINIFY:$SDK_MINIFY_TERSER" = 0:none ] || {
    [ "$SDK_MINIFY" = 1 ] && [[ "$SDK_MINIFY_TERSER" =~ ^5\.[0-9]+\.[0-9]+$ ]]
  }; then
    [ "$SDK_MINIFY:$SDK_MINIFY_TERSER" = "$expected_mode:$expected_terser" ] || {
      echo "ОШИБКА: $file — режим и версия не совпадают с закреплениями сборки; пересобери статику" >&2
      return 1
    }
    return 0
  fi
  echo "ОШИБКА: $file — ожидались SDK_MINIFY=0 и SDK_MINIFY_TERSER=none либо SDK_MINIFY=1 и версия Terser 5.x вида 5.<число>.<число>" >&2
  return 1
}

# Prints the overlay revision for the org.opencontainers.image.revision label in a local build:
# the HEAD of the git repository if the overlay directory is its root, otherwise unknown.
#   $1 — overlay directory
# An overlay snapshot without .git, unpacked inside another repository, is attributed by git to the
# enclosing repository, and its HEAD would describe someone else's code. So HEAD is taken only if the
# root of the working tree matches the overlay directory (both paths without symbolic links).
overlay_revision() {
  local dir top head

  dir=$(cd "$1" 2>/dev/null && pwd -P) || { echo unknown; return 0; }
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || { echo unknown; return 0; }
  top=$(cd "$top" 2>/dev/null && pwd -P) || { echo unknown; return 0; }
  [ "$top" = "$dir" ] || { echo unknown; return 0; }
  head=$(git -C "$dir" rev-parse --verify -q HEAD 2>/dev/null) || { echo unknown; return 0; }
  echo "$head"
}

# Checks that the listed keys of the file yielded non-empty values.
#   $1 — file (for the message), $2 — variable name prefix, the rest — keys
# An empty value has two origins (the key is absent from the file or it is set empty), and
# the consumer does not care: in both cases the value is missing. The message names
# the keys of the file, not the variable names: it is the file that gets fixed.
require_keys() {
  local file="$1" prefix="$2"
  shift 2
  local key name missing=()

  for key in "$@"; do
    name="$prefix$key"
    [ -n "${!name:-}" ] || missing+=("$key")
  done
  [ ${#missing[@]} -eq 0 ] || {
    echo "ОШИБКА: в $file нет значений для: ${missing[*]}" >&2
    return 1
  }
}

# --- release build ------------------------------------------------------------
# A release is an image that the "About" window describes with the release number and the source URL.
# The number is SOURCE_TAG without the leading v, the URL is SOURCE_URL. A release build (--release) checks
# both values before starting docker, and the built static files after the build.

# Editor directories in the web-apps static files: the desktop versions of all editors and the mobile versions
# of those that have them.
RELEASE_MAIN_EDITORS=(documenteditor spreadsheeteditor presentationeditor pdfeditor visioeditor)
RELEASE_MOBILE_EDITORS=(documenteditor spreadsheeteditor presentationeditor visioeditor)

# The common "About" window module of the desktop editors. The desktop editors are not bundled into
# one package: each includes the module by this name, and in the static files it lies as a single file
# apps/<name>.js for all five editors, not in an editor directory. The mobile versions are bundled
# as packages and carry the window in their own directory.
RELEASE_MAIN_ABOUT_MODULE='common/main/lib/view/About'

# Strings that must not be in the built static files of a release: unsubstituted placeholders
# of the address and the number, and the former link placeholder in a source code line.
RELEASE_FORBIDDEN_STRINGS=(
  '{{SOURCE_URL}}'
  '{{RELEASE_VERSION}}'
  'Source code: [link]'
  'Исходный код: [ссылка]'
)

# Prints the host of an address: the part between "scheme://" and the first /, ? or #, without credentials,
# port, and trailing dot, in lowercase. Empty if there is no host.
#   $1 — address
source_url_host() {
  local host="$1"

  host="${host#*://}"
  host="${host%%[/?#]*}"
  host="${host##*@}"
  host="${host%%:*}"
  host="${host%.}"
  echo "${host,,}"
}

# Exit code 0 if the address is a placeholder: the host ends with the reserved .invalid domain.
#   $1 — address
source_url_is_placeholder() {
  local host
  host=$(source_url_host "$1")
  [ "$host" = invalid ] || [[ "$host" == *.invalid ]]
}

# Prints the source URL for the static build: SOURCE_URL, or empty if it is a placeholder.
# A placeholder does not get into the window: the window of a local and a public build stays without a
# source code line rather than with a link that leads nowhere.
build_source_url() {
  if [ -z "${SOURCE_URL:-}" ] || source_url_is_placeholder "$SOURCE_URL"; then
    echo
  else
    echo "$SOURCE_URL"
  fi
}

# Prints the release number: the tag without the leading v.
#   $1 — release tag
release_version() {
  echo "${1#v}"
}

# Checks the release build pins: SOURCE_TAG and SOURCE_URL.
# The tag has the release form v<PRODUCT_VERSION>.<BUILD_NUMBER>-b24.N with N >= 1: the same label is later
# expected by image promotion (release_label_expected), and a mismatch is visible before the build rather than after
# it. The address is https:// with a non-empty host, not a placeholder, without a query (?) or fragment (#),
# ending in /<SOURCE_TAG> and consisting only of the characters A-Z a-z 0-9 . _ ~ : / @ % + = & -:
# the address goes into a JS string literal and into the window markup, so quotes, backslashes,
# spaces, and angle brackets are not allowed in it. Each mismatch is a separate
# error line with the key name; exit code 1 if there is at least one.
check_release_inputs() {
  local tag="${SOURCE_TAG:-}" url="${SOURCE_URL:-}" failed=0
  local tag_re='^v[0-9]+(\.[0-9]+)*-b24\.[1-9][0-9]*$'
  local url_re='^[A-Za-z0-9._~:/@%+=&-]+$'

  if ! [[ "$tag" =~ $tag_re ]]; then
    echo "ОШИБКА: SOURCE_TAG='$tag' — не тег выпуска вида v9.4.0.129-b24.N с номером выпуска N от 1" >&2
    failed=1
  elif [[ "$tag" != "v${PRODUCT_VERSION:-}.${BUILD_NUMBER:-}-b24."* ]]; then
    echo "ОШИБКА: SOURCE_TAG='$tag' — не совпадает с версией сборки: ожидался v${PRODUCT_VERSION:-<PRODUCT_VERSION>}.${BUILD_NUMBER:-<BUILD_NUMBER>}-b24.N, такую метку ждёт продвижение образа" >&2
    failed=1
  fi

  if [ -z "$url" ]; then
    echo "ОШИБКА: SOURCE_URL пуст — окну выпуска нечем назвать адрес исходников" >&2
    failed=1
  else
    [[ "$url" == https://* ]] || {
      echo "ОШИБКА: SOURCE_URL='$url' — адрес исходников выпуска обязан начинаться с https://" >&2
      failed=1
    }
    [ -n "$(source_url_host "$url")" ] || {
      echo "ОШИБКА: SOURCE_URL='$url' — в адресе нет хоста" >&2
      failed=1
    }
    [[ "$url" != *[?#]* ]] || {
      echo "ОШИБКА: SOURCE_URL='$url' — запрос (?) или фрагмент (#) в адресе: ссылка обязана вести на страницу тега выпуска" >&2
      failed=1
    }
    ! source_url_is_placeholder "$url" || {
      echo "ОШИБКА: SOURCE_URL='$url' — заглушка домена .invalid, а выпуску нужен настоящий адрес исходников" >&2
      echo "  адрес задаётся в versions.env или аргументом --override SOURCE_URL=<адрес>" >&2
      failed=1
    }
    [[ "$url" =~ $url_re ]] || {
      echo "ОШИБКА: SOURCE_URL — в адресе есть недопустимые символы; разрешены только A–Z a–z 0–9 . _ ~ : / @ % + = & -" >&2
      failed=1
    }
    [ -n "$tag" ] && [[ "$url" == */"$tag" ]] || {
      echo "ОШИБКА: SOURCE_URL='$url' — адрес не ведёт на тег выпуска: он обязан оканчиваться на /${tag:-<SOURCE_TAG>}" >&2
      failed=1
    }
  fi

  return "$failed"
}

# Exit code 0 if at least one *.js on the path (directory or file) contains both the address and the release number.
# The number is searched for as a separate quoted string literal ("...", '...' or `...`): the address
# ends in /v<number>, and an occurrence of the number inside the address does not prove that the number
# was substituted on its own.
#   $1 — directory or file, $2 — source URL, $3 — release number
release_js_has_source() {
  local path="$1" url="$2" version="$3" file

  while IFS= read -r -d '' file; do
    grep -q -F -e "\"$version\"" -e "'$version'" -e "\`$version\`" -- "$file" && return 0
  done < <(grep -r -l -Z -F --include='*.js' -- "$url" "$path")
  return 1
}

# Checks the built web-apps static files of a release.
#   $1 — static root (the directory with apps/), $2 — source URL, $3 — release number
# The "About" window of each editor names the address and the number (release_js_has_source):
# - the mobile version: any *.js in the apps/<editor>/mobile directory;
# - the desktop version: either any *.js in apps/<editor>/main, or the common window module
#   (RELEASE_MAIN_ABOUT_MODULE) if the editor includes it by name. An editor that does not
#   include the common module and does not carry the address and number itself is a failure.
# No *.js or *.json under apps/ contains unsubstituted placeholders or the former
# link placeholder (RELEASE_FORBIDDEN_STRINGS). A failure names each directory and file where
# something is wrong; exit code 1.
check_release_static() {
  local root="$1" url="$2" version="$3"
  local editor dir file needle problems=() about_users=()
  local about="apps/$RELEASE_MAIN_ABOUT_MODULE.js"
  local about_ref="[\"'\`]$RELEASE_MAIN_ABOUT_MODULE[\"'\`]"

  [ -n "$url" ] && [ -n "$version" ] || {
    echo "ОШИБКА: проверка статики выпуска без адреса или номера — сверять не с чем" >&2
    return 1
  }
  [ -d "$root/apps" ] || {
    echo "ОШИБКА: $root/apps — нет каталога собранной статики web-apps" >&2
    return 1
  }

  for editor in "${RELEASE_MAIN_EDITORS[@]}"; do
    dir="apps/$editor/main"
    if [ ! -d "$root/$dir" ]; then
      problems+=("$dir — каталога нет")
    elif release_js_has_source "$root/$dir" "$url" "$version"; then
      :
    elif grep -r -q -E --include='*.js' -- "$about_ref" "$root/$dir"; then
      about_users+=("$editor")
    else
      problems+=("$dir — окно не подключает общий модуль $RELEASE_MAIN_ABOUT_MODULE, и ни один *.js редактора не содержит вместе адрес $url и номер $version")
    fi
  done

  if [ ${#about_users[@]} -gt 0 ]; then
    if [ ! -f "$root/$about" ]; then
      problems+=("$about — файла нет, а окно настольных редакторов подключает его: ${about_users[*]}")
    elif ! release_js_has_source "$root/$about" "$url" "$version"; then
      problems+=("$about — общее окно настольных редакторов (${about_users[*]}) не содержит вместе адрес $url и номер $version")
    fi
  fi

  for editor in "${RELEASE_MOBILE_EDITORS[@]}"; do
    dir="apps/$editor/mobile"
    if [ ! -d "$root/$dir" ]; then
      problems+=("$dir — каталога нет")
    elif ! release_js_has_source "$root/$dir" "$url" "$version"; then
      problems+=("$dir — ни один *.js не содержит вместе адрес $url и номер $version")
    fi
  done

  for needle in "${RELEASE_FORBIDDEN_STRINGS[@]}"; do
    while IFS= read -r -d '' file; do
      problems+=("${file#"$root/"} — содержит «$needle»")
    done < <(grep -r -l -Z -F --include='*.js' --include='*.json' -- "$needle" "$root/apps")
  done

  [ ${#problems[@]} -eq 0 ] || {
    echo "ОШИБКА: статика выпуска в $root не готова — окно «О программе» не назовёт адрес и номер выпуска:" >&2
    printf '  %s\n' "${problems[@]}" >&2
    return 1
  }
}

# Prints the release label that the release build sets and image promotion expects:
# v<PRODUCT_VERSION>.<BUILD_NUMBER>-b24.<N>.
#   $1 — release number N
release_label_expected() {
  local n="${1:-}"

  [[ "$n" =~ ^[1-9][0-9]*$ ]] && [ -n "${PRODUCT_VERSION:-}" ] && [ -n "${BUILD_NUMBER:-}" ] || {
    echo "ОШИБКА: метку выпуска не построить: номер выпуска '$n', PRODUCT_VERSION='${PRODUCT_VERSION:-}', BUILD_NUMBER='${BUILD_NUMBER:-}'" >&2
    return 1
  }
  echo "v$PRODUCT_VERSION.$BUILD_NUMBER-b24.$n"
}

# Manifest types under which the registry stores an index (OCI image index and the former docker
# manifest list), as opposed to the manifest of a single image.
RELEASE_INDEX_MEDIA_TYPES=(
  application/vnd.oci.image.index.v1+json
  application/vnd.docker.distribution.manifest.list.v2+json
)

# Exit code 0 if the manifest type is an index (RELEASE_INDEX_MEDIA_TYPES).
#   $1 — manifest type from the registry response (manifest_media_type)
release_is_index_media_type() {
  local media_type="$1" index_type

  for index_type in "${RELEASE_INDEX_MEDIA_TYPES[@]}"; do
    if [ "$media_type" = "$index_type" ]; then
      return 0
    fi
  done
  return 1
}

# The platform of the release image inside the index: the release labels are read from its image.
RELEASE_IMAGE_PLATFORM='linux/amd64'

# Prints the overlay.release label of an artifact from the Harbor API response for the artifact.
#   $1 — a function that prints the API response for an artifact by its digest (non-zero code means the artifact was not
#        obtained), $2 — artifact digest
# The image labels live in its configuration (extra_attrs.config.Labels). docker build publishes the
# image as an index: the platform image and the attestation manifest, and the index has no configuration of its own.
# So for an index the label is read from the child image of the RELEASE_IMAGE_PLATFORM platform: the response
# for the index lists the children in references with platform and digest, and the child is requested
# by the same function. For a plain image the label is read from the image itself. If there is no child of this platform,
# there are several, the child is itself an index, or the image has no label, it is a failure naming the place;
# exit code 1.
release_artifact_label() {
  local fetch="$1" digest="$2" meta media_type child="" label is_index=0
  local digest_re='^sha256:[0-9a-f]{64}$'
  local want_os="${RELEASE_IMAGE_PLATFORM%%/*}" want_arch="${RELEASE_IMAGE_PLATFORM#*/}"

  meta=$("$fetch" "$digest") || {
    echo "ОШИБКА: реестр не отдал артефакт $digest — метку выпуска проверить нечем" >&2
    return 1
  }
  media_type=$(jq -r '.manifest_media_type // empty' <<<"$meta" 2>/dev/null) || {
    echo "ОШИБКА: ответ реестра на артефакт $digest не разбирается — метку выпуска проверить нечем" >&2
    return 1
  }
  if release_is_index_media_type "$media_type"; then
    is_index=1
    child=$(jq -r --arg os "$want_os" --arg arch "$want_arch" '
      [.references // [] | .[]
        | select(.platform.os == $os and .platform.architecture == $arch)
        | .child_digest]
      | if length == 1 then .[0] else "count:\(length)" end
    ' <<<"$meta" 2>/dev/null) || {
      echo "ОШИБКА: ответ реестра на индекс $digest не разбирается — метку выпуска проверить нечем" >&2
      return 1
    }
    [[ "$child" =~ $digest_re ]] || {
      echo "ОШИБКА: в индексе $digest нет ровно одного образа платформы $RELEASE_IMAGE_PLATFORM (найдено: ${child#count:})" >&2
      echo "  метки выпуска читаются из образа этой платформы (поле references ответа реестра)" >&2
      return 1
    }
    meta=$("$fetch" "$child") || {
      echo "ОШИБКА: реестр не отдал образ $child платформы $RELEASE_IMAGE_PLATFORM индекса $digest — метку выпуска проверить нечем" >&2
      return 1
    }
    media_type=$(jq -r '.manifest_media_type // empty' <<<"$meta" 2>/dev/null) || {
      echo "ОШИБКА: ответ реестра на образ $child индекса $digest не разбирается — метку выпуска проверить нечем" >&2
      return 1
    }
    if release_is_index_media_type "$media_type"; then
      echo "ОШИБКА: потомок $child платформы $RELEASE_IMAGE_PLATFORM индекса $digest сам индекс, а не образ" >&2
      return 1
    fi
  fi

  label=$(jq -r '.extra_attrs.config.Labels["overlay.release"] // empty' <<<"$meta" 2>/dev/null) || {
    echo "ОШИБКА: ответ реестра на артефакт ${child:-$digest} не разбирается — метку выпуска проверить нечем" >&2
    return 1
  }
  [ -n "$label" ] || {
    if [ "$is_index" -eq 1 ]; then
      echo "ОШИБКА: у образа $child платформы $RELEASE_IMAGE_PLATFORM индекса $digest нет метки overlay.release — он собран не в режиме выпуска" >&2
    else
      echo "ОШИБКА: у артефакта $digest нет метки overlay.release — он собран не в режиме выпуска" >&2
    fi
    echo "  продвигается только образ, собранный джобой build с проверкой окна «О программе»" >&2
    echo "  (метки читаются из поля extra_attrs.config.Labels ответа реестра на образ)" >&2
    return 1
  }
  echo "$label"
}

# Checks the finished API against an explicit pin or against the base image reference.
# A non-empty pin is mandatory and does not allow skipping the check.
# $1 — finished api.js.tpl, $2 — official reference, $3 — pin, $4 — bypass for a missing reference.
check_api_template() {
  local template="$1" reference="$2" expected="$3" allow_missing="$4" actual want
  actual=$(sha256sum "$template" | cut -d' ' -f1) || return 1
  if [ -n "$expected" ]; then
    [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || {
      echo "ОШИБКА: EXPECTED_API_TPL_SHA256 — ожидалось 64 строчных шестнадцатеричных знака" >&2
      return 1
    }
    [ "$actual" = "$expected" ] || {
      echo "ОШИБКА: api.js.tpl не совпал с EXPECTED_API_TPL_SHA256" >&2
      echo "  получено: $actual  ($template)" >&2
      echo "  ожидалось: $expected" >&2
      return 1
    }
    echo "==> СВЕРКА: api.js.tpl совпал с EXPECTED_API_TPL_SHA256 ($actual)"
  elif [ -f "$reference" ]; then
    want=$(sha256sum "$reference" | cut -d' ' -f1) || return 1
    [ "$actual" = "$want" ] || {
      echo "ОШИБКА: api.js.tpl не совпал с эталоном" >&2
      echo "  получено: $actual  ($template)" >&2
      echo "  эталон:   $want  ($reference)" >&2
      echo "  разберись в причине, руками не подгоняй" >&2
      return 1
    }
    echo "==> СВЕРКА: api.js.tpl побайтово совпал с эталоном образа ($actual)"
  elif [ "$allow_missing" = 1 ]; then
    echo "==> ПРЕДУПРЕЖДЕНИЕ: СВЕРКА пропущена по --allow-no-reference — эталон $reference недоступен"
  else
    echo "ОШИБКА: эталон $reference недоступен — сверять api.js.tpl не с чем" >&2
    return 1
  fi
}
