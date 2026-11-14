#!/usr/bin/env bash
# Comparison of the built static files with the contents of the official image
# onlyoffice/documentserver:9.4.0.1.
#
# Left (build): <root>/sdkjs/deploy/sdkjs and <root>/web-apps/deploy/web-apps
# Right (reference): <reference>/sdkjs and <reference>/web-apps (docker cp from the image)
#
# Files are compared by sha256 and differences are sorted into categories. Pre-compressed *.gz
# are excluded on both sides: documentserver-static-gzip.sh creates them when the container starts.
#
#   bash overlay/compare.sh                                              # root is the directory above overlay
#   bash overlay/compare.sh --root <fork> --reference <fork>/_ref/image
#   bash overlay/compare.sh --json report.json                           # also write a JSON report
#   bash overlay/compare.sh --help                                       # help
set -euo pipefail

# --- parameters --------------------------------------------------------------
OVERLAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Сравнение собранной статики (sdkjs, web-apps) с эталоном из официального образа.

  bash compare.sh [--root КАТАЛОГ] [--reference КАТАЛОГ] [--json ФАЙЛ]

  --root КАТАЛОГ        корень форка с клонами sdkjs и web-apps; сравнивается их deploy/
                        (по умолчанию — каталог над overlay)
  --reference КАТАЛОГ   эталон: каталог с sdkjs и web-apps, извлечёнными из образа
                        (по умолчанию — <root>/_ref/image)
  --json ФАЙЛ           дополнительно записать полный отчёт в ФАЙЛ в формате JSON
  -h, --help            эта справка
USAGE
}

root_dir=""
reference_dir=""
json_path=""

# Value of a flag's required argument; without it, fail with a pointer to the help.
need_value() {
  [ "$2" -ge 2 ] || {
    echo "ОШИБКА: $1 без значения" >&2
    echo "  справка: bash compare.sh --help" >&2
    exit 1
  }
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --root)
      need_value "$1" $#
      root_dir="$2"
      shift 2
      ;;
    --reference)
      need_value "$1" $#
      reference_dir="$2"
      shift 2
      ;;
    --json)
      need_value "$1" $#
      json_path="$2"
      shift 2
      ;;
    *)
      echo "ОШИБКА: неизвестный аргумент '$1'" >&2
      echo "  справка: bash compare.sh --help" >&2
      exit 1
      ;;
  esac
done

root_dir="${root_dir:-$OVERLAY_DIR/..}"
[ -d "$root_dir" ] || { echo "ОШИБКА: нет каталога корня: $root_dir" >&2; exit 1; }
root_dir="$(cd "$root_dir" && pwd)"

reference_dir="${reference_dir:-$root_dir/_ref/image}"
# Without a reference the comparison is meaningless: everything built would end up "only in the build".
[ -d "$reference_dir" ] || {
  echo "ОШИБКА: нет каталога эталона: $reference_dir" >&2
  echo "  задайте его флагом --reference или извлеките эталон из образа (README, «Локальный каталог _ref»)" >&2
  exit 1
}
reference_dir="$(cd "$reference_dir" && pwd)"

export COMPARE_ROOT="$root_dir" COMPARE_REFERENCE="$reference_dir" COMPARE_JSON="$json_path"

python3 - <<'PY'
import collections
import hashlib
import json
import os

ROOT = os.environ['COMPARE_ROOT']
REFERENCE = os.environ['COMPARE_REFERENCE']
JSON_PATH = os.environ['COMPARE_JSON']
PAIRS = [
    ('sdkjs',    os.path.join(ROOT, 'sdkjs', 'deploy', 'sdkjs'),        os.path.join(REFERENCE, 'sdkjs')),
    ('web-apps', os.path.join(ROOT, 'web-apps', 'deploy', 'web-apps'),  os.path.join(REFERENCE, 'web-apps')),
]

# Categories of expected differences. They are checked in order; the first match wins.
def categorize(tree, rel):
    tree_rel = tree + '/' + rel
    if tree_rel == 'sdkjs/common/AllFonts.js':
        return 'generated:allfonts (documentserver-generate-allfonts.sh при старте)'
    if tree_rel.startswith('sdkjs/common/Images/fonts_thumbnail'):
        return 'generated:font-thumbnails (allfontsgen при старте)'
    if tree_rel.startswith('sdkjs/common/Images/theme'):
        return 'generated:theme-thumbnails (allthemesgen при старте)'
    if tree_rel.startswith('sdkjs/common/serviceworker/'):
        return 'generated:serviceworker'
    if tree_rel.startswith('sdkjs/common/Native/') or tree_rel.startswith('sdkjs/common/Charts/'):
        return 'x2t-jscache (Native/Charts, кладёт сборка build_tools)'
    if tree_rel.endswith('.bin'):
        return 'binary:*.bin (движок из core/x2t, вне JS-сборки)'
    if tree_rel == 'web-apps/apps/api/documents/api.js':
        return 'generated:api.js (рендерится из api.js.tpl при старте)'
    if tree_rel == 'web-apps/apps/api/documents/api.js.tpl':
        return 'template:api.js.tpl (шаблон, создаётся упаковщиком образа)'
    return 'other'

def walk(top):
    out = {}
    if not os.path.isdir(top):
        return out
    for dirpath, dirnames, filenames in os.walk(top):
        for name in filenames:
            if name.endswith('.gz'):
                continue
            full = os.path.join(dirpath, name)
            if os.path.islink(full) and not os.path.exists(full):
                continue
            out[os.path.relpath(full, top)] = full
    return out

def sha(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()

report = {}
for tree, build_root, image_root in PAIRS:
    built = walk(build_root)
    image = walk(image_root)
    only_build = sorted(set(built) - set(image))
    only_image = sorted(set(image) - set(built))
    common = sorted(set(built) & set(image))

    same, diff = [], []
    for rel in common:
        if os.path.getsize(built[rel]) != os.path.getsize(image[rel]):
            diff.append(rel)
        elif sha(built[rel]) == sha(image[rel]):
            same.append(rel)
        else:
            diff.append(rel)

    report[tree] = {
        'build_root': build_root, 'image_root': image_root,
        'total_build': len(built), 'total_image': len(image),
        'common': len(common), 'same': len(same), 'diff': len(diff),
        'only_build': only_build, 'only_image': only_image,
        'diff_files': diff,
        'diff_by_cat': collections.Counter(categorize(tree, rel) for rel in diff),
        'only_image_by_cat': collections.Counter(categorize(tree, rel) for rel in only_image),
        'only_build_by_cat': collections.Counter(categorize(tree, rel) for rel in only_build),
    }

for tree, entry in report.items():
    print('=' * 78)
    print(f"[{tree}]  build={entry['build_root']}")
    print(f"{'':9}image={entry['image_root']}")
    print(f"  файлов в сборке: {entry['total_build']}   в образе: {entry['total_image']}   общих: {entry['common']}")
    print(f"  совпало по sha256: {entry['same']}   расходится: {entry['diff']}")
    print(f"  только в сборке: {len(entry['only_build'])}   только в образе: {len(entry['only_image'])}")
    for title, key in (('расходящиеся по категориям', 'diff_by_cat'),
                       ('только в образе, по категориям', 'only_image_by_cat'),
                       ('только в сборке, по категориям', 'only_build_by_cat')):
        if entry[key]:
            print(f"  -- {title}:")
            for cat, count in entry[key].most_common():
                print(f"     {count:6}  {cat}")
    for key, title in (('diff_files', 'расходящиеся'), ('only_image', 'только в образе'), ('only_build', 'только в сборке')):
        rest = [rel for rel in entry[key] if categorize(tree, rel) == 'other']
        if rest:
            print(f"  -- {title}, категория other ({len(rest)}), первые 40:")
            for rel in rest[:40]:
                print(f"     {rel}")

if JSON_PATH:
    with open(JSON_PATH, 'w', encoding='utf-8') as out:
        json.dump({tree: {key: (dict(value) if isinstance(value, collections.Counter) else value)
                          for key, value in entry.items()} for tree, entry in report.items()},
                  out, ensure_ascii=False, indent=1)
    print(f"\nJSON: {JSON_PATH}")
PY
