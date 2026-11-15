# OnlyOffice Document Server overlay image

A build of the Document Server image in which the **JavaScript static files** (`web-apps`, `sdkjs`
with the `sdkjs-forms` add-on) are rebuilt from the fork's sources and overlaid on top of the
official image `onlyoffice/documentserver:9.4.0.1`.

**The binary part has not been modified.** Server, x2t (core), fonts and dictionaries are neither
rebuilt nor modified: they are taken as is from the official ONLYOFFICE image of this version
(`BASE_IMAGE` in `versions.env`, pinned by digest). Only the static files are rebuilt, and their
build reproduces the official packaging — this is confirmed by verifying `api.js.tpl` against the
reference (section "Post-processing and verification: prepare.sh"). The base image contains no
plugins, and the image disables loading them at startup (section "Plugins"). The only binary
addition is the nginx module `brotli_static` from the Ubuntu package of the same release as the
base's nginx: it serves brotli copies of the static files compressed at build time
(section "Brotli compression").

The license is GNU AGPLv3, section "License".

| File | What it is |
|---|---|
| `versions.env` | build pins: base image, source tag, revisions, source URLs |
| `build-static.sh` | builds the JS static files from the source clones |
| `prepare.sh` | post-processes the static files, verifies them against the reference and prepares the image context |
| `build.sh` | prepares the context and runs `docker build` |
| `lib.sh` | shared script functions: reading the pins, registry checks, release build checks |
| `compare.sh` | compares the built static files with the official image |
| `tools/sdk-minify.cjs` | minifies six SDK files with the pinned Terser without compress and mangle |
| `Dockerfile`, `.dockerignore` | the image: the official base plus the overlaid static files |
| `documentserver-flush-cache.sh` | the image's wrapper: content-based static files version (section "Static files version") |
| `LICENSE` | the GNU AGPLv3 text |

The complete build order: sources (section "Sources") → static files (`build-static.sh`) → context
and verification (`prepare.sh`, called by `build.sh`) → image (`build.sh`) → run
(section "Running the built image").

## Sources

Four repositories and the base image are needed; all pins are in `versions.env`
(section "Build pins"):

| What | Address | Revision |
|---|---|---|
| `web-apps` fork | `WEB_APPS_URL` | tag `SOURCE_TAG` (a release tag of the form `v9.4.0.129-b24.N`; the value is in `versions.env`) |
| `sdkjs` fork | `SDKJS_URL` | tag `SOURCE_TAG` |
| `sdkjs-forms` fork | `SDKJS_FORMS_URL` | tag `SOURCE_TAG` |
| ONLYOFFICE `build_tools` | `BUILD_TOOLS_URL` (`https://github.com/ONLYOFFICE/build_tools`) | `BUILD_TOOLS_REV`, full SHA |
| base image | `BASE_IMAGE` (Docker Hub) | digest `sha256:…` |

`versions.env` records the URLs of the forks' public repositories. The build does not read these
keys — the scripts use existing clone directories; the keys sit next to `SOURCE_TAG` and
`BUILD_TOOLS_REV` so that the address and the revision are set in one place.

The `SOURCE_TAG` tag exists only in the forks; ONLYOFFICE does not have it. In `web-apps` and
`sdkjs` it points to the commit with the fork's changes; in `sdkjs-forms` it points to the same
commit as the upstream tag `v9.4.0.129`: the code of that repository is identical to upstream.

### Clones

All three sources sit side by side in the fork root (section "Directory layout"): this is where the
build scripts look for them — `sdkjs/build/build.py` resolves `--addon=sdkjs-forms` relative to the
parent directory of `sdkjs/`.

```bash
FORK=<fork root>        # the directory that contains overlay/
cd "$FORK"
val() { grep "^$1=" overlay/versions.env | cut -d= -f2-; }
SOURCE_TAG=$(val SOURCE_TAG)
WEB_APPS_URL=$(val WEB_APPS_URL)
SDKJS_URL=$(val SDKJS_URL)
SDKJS_FORMS_URL=$(val SDKJS_FORMS_URL)
git clone --branch "$SOURCE_TAG" --depth 1 "$WEB_APPS_URL"    web-apps
git clone --branch "$SOURCE_TAG" --depth 1 "$SDKJS_URL"       sdkjs
git clone --branch "$SOURCE_TAG" --depth 1 "$SDKJS_FORMS_URL" sdkjs-forms
```

The clones are shallow (`--depth 1`). When the history is needed — for example, to move your changes
onto a new tag — it is fetched in place:

```bash
git -C sdkjs fetch --unshallow
git -C sdkjs fetch --tags
```

`build_tools` is cloned into the local `_ref/` directory (section "Local _ref directory").

## Directory layout

The scripts know no absolute paths: `build-static.sh`, `prepare.sh` and `build.sh` derive the fork
root from their own location — `FORK_DIR` = the directory above `overlay/`. Hence the default
layout: the overlay repository is cloned **as the `overlay/` directory inside** a tree that also
holds the source clones and the local `_ref/` directory.

```text
<fork root>/             # FORK_DIR
├── overlay/             # this repository
├── web-apps/
├── sdkjs/
├── sdkjs-forms/
└── _ref/                # local working directory, part of neither the repository nor the image
    ├── build_tools/     # build_tools clone at BUILD_TOOLS_REV
    └── image/           # reference static files from the base image
```

| Path | What it is |
|---|---|
| `overlay/` | this repository; the image build context is `overlay/context/` (in `.gitignore`) |
| `web-apps/` | clone of the `web-apps` fork at tag `SOURCE_TAG`; the build output is `web-apps/deploy/web-apps` |
| `sdkjs/` | clone of the `sdkjs` fork at tag `SOURCE_TAG`; the build output is `sdkjs/deploy/sdkjs` |
| `sdkjs-forms/` | clone of the `sdkjs-forms` fork at tag `SOURCE_TAG`; an add-on included in the sdkjs build |
| `_ref/build_tools/` | clone of the ONLYOFFICE build scripts; their Python code is executed by `prepare.sh` |
| `_ref/image/` | reference static files from the official image (about 1 GB) for verification and comparison |

The root can also be set explicitly, `FORK_DIR=<path>`: all three scripts accept it, and `build.sh`
passes the derived value to `prepare.sh` via `export`. The same layout is expected inside the given
root.

The layout next to `overlay/` is only the default, not a build requirement: each directory can also
be set on its own — `WEBAPPS_DIR`, `SDKJS_DIR`, `SDKJS_FORMS_DIR`, `BUILD_TOOLS_DIR`,
`REFERENCE_TPL`, `SOURCES_DIR`, and for `build-static.sh` also `CACHE_DIR`. This is how to build
where the sources live separately from overlay. The context directory, however, is always derived
from the overlay directory itself (`overlay/context`) — that is where `COPY` in the `Dockerfile`
takes it from. `SDKJS_FORMS_DIR` must be a sibling of `SDKJS_DIR` named `sdkjs-forms`: the sdkjs
build includes the add-on by a relative path.

### Local _ref directory

`_ref/` is an optional local working directory in the fork root: by default it holds the
`build_tools` clone and the reference from the base image. It is part of neither the repository nor
the image, and both directories can be kept anywhere by setting `BUILD_TOOLS_DIR` and
`REFERENCE_TPL`.

The `build_tools` clone at the pinned revision:

```bash
cd "$FORK"
git clone "$(val BUILD_TOOLS_URL)" _ref/build_tools
git -C _ref/build_tools checkout "$(val BUILD_TOOLS_REV)"
```

This clone is not shallow: `--depth 1` gives only the tip of `master`, while exactly this revision
is needed. It is pinned because `prepare.sh` executes Python code from the clone (`make.py` imports
`base.py` from it), and the result is embedded into `api.js` — the entry point of the whole client
side. `build_tools` has no tags corresponding to release 9.4.0.129, and `master` moves, so the pin
is a full SHA. `prepare.sh` checks `git rev-parse HEAD` against it and requires the working tree to
be clean in tracked files: a change in the tree would alter the executed code without moving `HEAD`.

The reference static files are extracted from the base image without starting a container — so they
do not yet contain the files created at startup. The image is taken from the `BASE_IMAGE` pin, that
is, by digest: a reference taken by a mutable tag would one day turn out to be the static files of a
different build.

```bash
cd "$FORK"
BASE_IMAGE=$(val BASE_IMAGE)
docker pull "$BASE_IMAGE"
docker create --name oo-ref "$BASE_IMAGE"
mkdir -p _ref/image
docker cp oo-ref:/var/www/onlyoffice/documentserver/web-apps - \
  | tar -x --no-same-permissions --no-same-owner -C _ref/image
docker cp oo-ref:/var/www/onlyoffice/documentserver/sdkjs - \
  | tar -x --no-same-permissions --no-same-owner -C _ref/image
docker rm oo-ref
```

A direct `docker cp` into a directory does not work: directories inside the image have mode `0555`,
and the client fails with `mkdirat …: permission denied`. Hence the tar stream with permission
normalization.

The reference for verification is `_ref/image/web-apps/apps/api/documents/api.js.tpl` (the default
value of `REFERENCE_TPL`); it alone is enough for verification, while the whole `_ref/image` is
needed for comparison (section "Equivalence check"). **With an empty `EXPECTED_API_TPL_SHA256`, the
image build stops if there is no reference:** verification of `api.js.tpl` is mandatory and can be
skipped only with the explicit `--allow-no-reference` argument.

## Build pins

Everything the image is built from is set in a single file — `versions.env`. There is no second
place: repeating a pin in another file is considered a defect.

| Key | What it sets | Read by |
|---|---|---|
| `BASE_IMAGE` | the base image together with its digest, Docker Hub | `build.sh`, the reference |
| `IMAGE_TAG_BASE` | the base image version, the tag prefix of the image being built | `build.sh` |
| `IMAGE_REPO` | the repository of the image being built; by default the local name `localhost/documentserver-overlay` | `build.sh` |
| `SOURCE_TAG` | the tag the source clones must be at; without the leading `v` it is the release number in the "About" window | `prepare.sh`, `build-static.sh`, `build.sh --release` |
| `SOURCE_URL` | the source code address that the "About" window shows next to the release number: the release tag page in the public overlay repository | `build-static.sh`, `build.sh --release` |
| `SDK_MINIFY` | the SDK minification mode: `1` by default, only `0` or `1` | all three build scripts |
| `TERSER_VERSION` | the exact Terser version, currently `5.28.1`; format `5.<number>.<number>` | all three build scripts, the tool check in `build-static.sh` |
| `BUILD_TOOLS_REV` | the revision of `build_tools` whose Python code is executed during preparation | `prepare.sh` |
| `PRODUCT_VERSION`, `BUILD_NUMBER` | the version and build number of the static files (`?_dc=<version>-<number>`) | `prepare.sh`, `build-static.sh` |
| `NODE_IMAGE`, `NPM_REGISTRY` | the Node image and the npm registry for building the static files | `build-static.sh` |
| `BUILD_TOOLS_URL`, `WEB_APPS_URL`, `SDKJS_URL`, `SDKJS_FORMS_URL` | source URLs for cloning | a person, section "Sources" |

The format is `KEY=value`, one pair per line, without quotes and without spaces around the equals
sign; comments start with `#`. An empty value (`KEY=`) means "default" — this is how `NPM_REGISTRY`
is set. `build-static.sh`, `prepare.sh` and `build.sh` read the file with a shared function from
`lib.sh` before any checks. The file is **not executed**: lines are parsed one by one, and each
value goes into its variable bypassing shell expansion, so `$(…)` in a value would remain text. A
malformed line or an unknown key stops the script with the line number.

**The file is the only source of pins.** An environment variable named after a key does not change
its value. A key that is missing from the file yields an empty value rather than picking up the
environment variable of the same name. Otherwise whoever runs the build would choose the images
whose code runs on the build machine, and the committed file would decide nothing.

**Deviating from the file requires the explicit `--override KEY=value` argument.** `build.sh`,
`build-static.sh` and `prepare.sh` accept it; `build.sh` passes its overrides on to `prepare.sh`.
The flag is repeatable, the key must be one of the keys of `versions.env`, and the value must follow
the same grammar as in the file (no spaces). This is how to take images from your own Docker Hub
mirror or name the built image with the address of your own registry:

```bash
bash "$FORK/overlay/build.sh" \
  --override BASE_IMAGE=mirror.example.com/onlyoffice/documentserver:9.4.0.1@sha256:<digest> \
  --override IMAGE_REPO=registry.example.com/documentserver-overlay
```

Each override is printed as a warning (key only): what is built this way differs from what is built
from the file, and this must be visible in the log. A CI pipeline, if there is one, supplies its
addresses the same way — with `--override` arguments.

**An image address may only use an allowed registry.** The values of `BASE_IMAGE`, `NODE_IMAGE` and
`IMAGE_REPO` set the images whose code runs on the build machine and the place where the built image
goes, so their registry is verified against the `REGISTRY_ALLOWED_BY_KEY` table in `lib.sh`:
`BASE_IMAGE` and `NODE_IMAGE` — only Docker Hub (`docker.io`), `IMAGE_REPO` — only `localhost`. The
registry is determined by docker's rules: the first segment of a reference is a registry only if it
contains a dot or a colon or is `localhost`; otherwise (`onlyoffice/documentserver`, `node:24`) it
is Docker Hub. The verification runs on every read of the file and **before** the first `docker run`
and `docker build`; a mismatch stops the script with exit code 1 and a list of the keys. An empty
value is skipped — that is how `NODE_IMAGE` turns off the containerized build. Values set with the
`--override` argument are exempt from the table: this is a deliberate decision of whoever runs the
build. The table itself is changed by a commit to `lib.sh`, not at run time.

For a build that logs in to its own registry and pushes the image there, `lib.sh` provides one more
check: `check_registry_fingerprint <sha256> <reference>…` verifies the registry host of each
reference against a pinned SHA-256 fingerprint (`printf '%s' <host> | sha256sum`) and refuses on a
mismatch, an empty reference or an empty fingerprint. This way the registry is pinned by a commit
without recording the address itself; the function prints nothing except the number of the
mismatching reference.

**The source code address is `SOURCE_URL`.** It is the release tag page in the public overlay
repository; the address ends with `/<SOURCE_TAG>` and changes together with it. A copy of overlay
without its own public repository can put a placeholder in the reserved `.invalid` domain here (for
example, `https://replace-with-overlay.invalid/`). The static files build does not pass the
placeholder to the window: web-apps gets an empty address instead, and the "About" window of a local
build has no source code line rather than a link that leads nowhere. A release build
(section "Release build") needs a real address — in the file or via the
`--override SOURCE_URL=<address>` argument.

A command that needs a pinned value gets it from the file:

```bash
BASE_IMAGE=$(grep '^BASE_IMAGE=' "$FORK/overlay/versions.env" | cut -d= -f2-)
```

**Moving to a new base** is a deliberate one-line change. The digest is taken from the actual value
of the new image and written into `BASE_IMAGE` in the form `repo:tag@sha256:…`: docker resolves the
reference by digest, while the tag stays readable in the labels and in the build log.

```bash
docker pull <new image>
docker image inspect <new image> --format '{{index .RepoDigests 0}}'
```

After the move, the reference is extracted again (section "Local _ref directory") and equivalence is
checked (section "Equivalence check"). The compression step of the `Dockerfile` installs the
`brotli` utility of the same version as the base's `libbrotli1` (section "Brotli compression"): if
in the new base this library comes from the Ubuntu release updates and the archive has already
replaced it with the next version, the step stops with an apt error. Then you need either a base
with an up-to-date `libbrotli1` or a deliberate decision to upgrade the library in the image — the
step currently forbids this by verifying the package list.

## Why the v9.4.0.129 tag

The `onlyoffice/documentserver:9.4.0.1` image contains the `onlyoffice-documentserver` package
version **9.4.0-129**: `web-apps/apps/api/documents/api.js` contains `_dc=9.4.0-129`, and
`sdkjs/word/sdk-all-min.js` contains `Version: 9.4.0 (build:129)`.

The last segment of the docker tag (`.1`) is the **image revision**, not the engine build number.
The sources correspond to the `v9.4.0.129` tag in all three repositories; the `v9.4.0.1` branch and
tag are a different, earlier commit and do not fit.

Fork releases are marked with tags of the form `v9.4.0.129-b24.N`, where `N` is the release number;
`SOURCE_TAG` equals the tag of the current release. There is one release number for everything, and
every part of a release can be found by it:

| Where | What release `N` carries |
|---|---|
| the editors' "About" window | the number `9.4.0.129-b24.N` — `SOURCE_TAG` without the leading `v` — and the source code address `SOURCE_URL` |
| the overlay repository | the tag `v9.4.0.129-b24.N` on the commit the release image is built from |
| the `web-apps`, `sdkjs`, `sdkjs-forms` forks | the tag `v9.4.0.129-b24.N` — the value of `SOURCE_TAG` in `versions.env` of that commit |
| the release image | the tag `<IMAGE_TAG_BASE>-b24.N` (currently `9.4.0.1-b24.N`) and the label `overlay.release=v9.4.0.129-b24.N` |

The number in the window equals the overlay tag, and the overlay tag equals the forks' `SOURCE_TAG`.
The address next to the number leads to the page of that tag, and `versions.env` at that tag names
everything else the image is built from: the forks' tag, the `build_tools` revision and the base
image by digest. The image tag prefix is the base image version `IMAGE_TAG_BASE`, not the static
files version: as stated above, `9.4.0.1` is the Document Server image version, while `9.4.0.129` is
the version and build number of the static files. The default image tag is `<IMAGE_TAG_BASE>-local`,
so a local test build cannot be mistaken for a release (section "Building the image").

A caveat: several tags point to the same commit, so `git describe --tags --exact-match` returns the
wrong tag (`v9.4.0.125` for web-apps, `v9.4.0.119` for sdkjs-forms). The correct check uses the list
of the commit's tags:

```bash
cd "$FORK"
SOURCE_TAG=$(grep '^SOURCE_TAG=' overlay/versions.env | cut -d= -f2-)
for repo in web-apps sdkjs sdkjs-forms; do
  tags=$(git -C "$repo" tag --points-at HEAD)
  grep -qxF "$SOURCE_TAG" <<<"$tags" && echo "$repo: ok" || echo "$repo: no tag; tags on HEAD: $tags"
done
```

The form is the same as in `prepare.sh`: the list of tags first goes into a variable, and the
comparison is done without a pipe. The familiar `tag --points-at HEAD | grep -qx …` is harmless for
an interactive check, but must not be copied into a script — `grep -q` closes the pipe after the
first match, and under `pipefail` a successful check would fail with SIGPIPE.

`prepare.sh` performs these same three checks itself before preparing the context; a deliberate
check against a different tag is set with the `--override SOURCE_TAG=<tag>` argument, not with an
environment variable.

## Environment requirements

The static files are built by `build-static.sh`, which by default does this in the `NODE_IMAGE`
container (section "Building the static files"). Therefore Node and npm are needed on the host only
for a build without a container — `bash "$FORK/overlay/build-static.sh" --override NODE_IMAGE=`.
python3 is always needed: `prepare.sh` runs it on the host.

| What | Version tested | Why |
|---|---|---|
| Docker | any with BuildKit | building the image; building the static files in the `NODE_IMAGE` container |
| bash | 5.1.16 | all scripts; version 4.4 or newer is required (associative arrays, `mapfile`) |
| Python | 3.10.12 | post-processing of `api.js` in `prepare.sh`; with an empty `NODE_IMAGE`, also the sdkjs build and `merge_and_check.py` |
| Node.js | 24.0.2 | only with an empty `NODE_IMAGE`: the web-apps build (grunt, webpack) |
| npm | 11.17.0 | only with an empty `NODE_IMAGE`: the web-apps dependencies |
| disk | ~15 GB | clones, npm dependencies and the download cache, `deploy/`, the build context, the reference, the image |

The Node and npm versions in the table are the same as in the `NODE_IMAGE` image.

Network access is needed to Docker Hub (the base image and the Node image), GitHub (clones;
`raw.githubusercontent.com` and GitHub's file delivery hosts — for the postinstall of the imagemin
packages), `registry.npmjs.org` (the web-apps dependencies) and the Ubuntu package archive according
to the base image's apt sources (`archive.ubuntu.com`, `security.ubuntu.com`): `docker build`
installs the nginx module and the `brotli` utility from it (section "Brotli compression").

Java is **not needed**: at this tag sdkjs is built by concatenation, and closure compiler is not
involved. `NODE_OPTIONS=--openssl-legacy-provider` is not required either — the build passes on Node
24 as is. There is no need to install grunt globally; `npx grunt` from the local dependencies is
used.

## Building the static files

A single command:

```bash
bash "$FORK/overlay/build-static.sh"
```

The script fills two directories from which `prepare.sh` makes the image context:
`web-apps/deploy/web-apps` and `sdkjs/deploy/sdkjs`. It follows the step order and environment
variables of the standard ONLYOFFICE pipeline (`build_tools/scripts/build_js.py`, the `make()`
function, the "builder" branch). A full build takes about 20 minutes; the first one, including
dependency installation, about half an hour. A rerun on the same revisions takes a fraction of a
second (section "Static files stamp").

The script has no pins of its own: it reads `PRODUCT_VERSION`, `BUILD_NUMBER`, `NODE_IMAGE` and
`NPM_REGISTRY`, `SDK_MINIFY` and `TERSER_VERSION` from `versions.env`. Help:
`bash "$FORK/overlay/build-static.sh" --help`.

### Steps

All steps share one set of environment variables: `COMPANY_NAME=ONLYOFFICE`,
`APP_CUSTOMER_NAME=ONLYOFFICE`, `PRODUCT_VERSION` and `BUILD_NUMBER` from the pins,
`NODE_ENV=production`, and for the "About" window, `SOURCE_URL` (the source code address; empty if
the pin is a placeholder) and `RELEASE_VERSION` (the release number — `SOURCE_TAG` without the
leading `v`). web-apps substitutes both values during the build.

1. **sdkjs** — `python3 build.py --beta=false --minimize --addon=sdkjs-forms --map` in
   `sdkjs/build`, seconds. The output is `sdkjs/deploy/sdkjs/{word,cell,slide,visio,pdf,common}`.
2. **web-apps** — `python3 merge_and_check.py` in `web-apps/translation`, then `npm install` and
   **two** full runs of `npx grunt --force` in `web-apps/build`. Each grunt pass takes about 10
   minutes; installing dependencies with an already populated `CACHE_DIR` takes seconds. The output
   is `web-apps/deploy/web-apps/{apps,vendor}`. The `web-apps/deploy/sdkjs` directory is created
   too, but does **not** go into the image: the official packaging takes only
   `web-apps/deploy/web-apps` and `sdkjs/deploy/sdkjs`.

The same steps by hand — this is an explanation of the script; the script itself is the source of
truth:

```bash
cd "$FORK"
PRODUCT_VERSION=$(grep '^PRODUCT_VERSION=' overlay/versions.env | cut -d= -f2-)
BUILD_NUMBER=$(grep '^BUILD_NUMBER=' overlay/versions.env | cut -d= -f2-)
SOURCE_TAG=$(grep '^SOURCE_TAG=' overlay/versions.env | cut -d= -f2-)
SOURCE_URL=$(grep '^SOURCE_URL=' overlay/versions.env | cut -d= -f2-)
SOURCE_URL=$(. overlay/lib.sh && build_source_url)   # .invalid placeholder → empty, as in the script
RELEASE_VERSION=${SOURCE_TAG#v}
export COMPANY_NAME=ONLYOFFICE APP_CUSTOMER_NAME=ONLYOFFICE PRODUCT_VERSION BUILD_NUMBER \
  SOURCE_URL RELEASE_VERSION NODE_ENV=production

cd "$FORK/sdkjs/build"          && python3 build.py --beta=false --minimize --addon=sdkjs-forms --map
cd "$FORK/web-apps/translation" && python3 merge_and_check.py
cd "$FORK/web-apps/build"       && npm install
npx grunt --force             # pass 1
npx grunt --force             # pass 2 — required, see below
```

`npm install`, not `npm ci`: this is how the standard ONLYOFFICE pipeline installs dependencies
(`build_js.py:107-111`), and only this way are they reused between runs — `npm ci` wipes the whole
directory before installing. The set of packages still comes from `package-lock.json`: the file is
tracked in the repository and consistent with `package.json`, and the script restores the sources'
working tree before each rebuild.

`COMPANY_NAME=ONLYOFFICE` is required: the default value in `sdkjs/build/build.py` is lowercase,
while the official static files have it in uppercase, and without the variable `word/sdk-all-min.js`
differs from the image. `APP_CUSTOMER_NAME=ONLYOFFICE` is required because the grunt default in the
fork's `web-apps` is a different product name, and the value is substituted into `customer=` in
`api.js`, so without the variable the verification of `api.js.tpl` fails. `APP_COPYRIGHT` and
`PUBLISHER_URL` do not need to be set — their default values match the image; the year in the
copyright line is taken from the system date.

The `sdkjs-forms` add-on is required: the official static files are built with it
(`window['Asc']['Addons']['forms']` in `word/sdk-all-min.js`); without it the file lacks about 966
lines. The `ooxml` add-on is not external — it lives inside sdkjs itself. `build.py` looks for the
add-on directory as a sibling of `sdkjs` named `sdkjs-forms` (`build.py:263-266`), so the script
checks this sibling arrangement before the build starts: a directory set in a way that bypasses it
would not break the build but would produce sdkjs without the add-on — and the discrepancy would
surface only at the verification of `api.js.tpl`.

grunt builds the mobile part itself — it installs dependencies in `web-apps/vendor/framework7-react`
and runs webpack (`npm run deploy-word|cell|slide|visio`). It does not need to be built separately.

### Where the steps run

By default, in the `NODE_IMAGE` container: then the same Node and npm run on any machine, and the
host needs only docker. The container runs as `$(id -u):$(id -g)` — files created as root would
break the cleanup of the working directory. The source directories and `CACHE_DIR` are mounted at
the same paths as on the host: the build scripts move between the clones by relative paths, and
matching paths inside and outside preserve these links. The home directory (`HOME`) and the npm
download cache (`npm_config_cache`) are moved into `CACHE_DIR`: the image's home directory belongs
to root, and npm would fail on the very first write to it.

```bash
bash "$FORK/overlay/build-static.sh" --override NODE_IMAGE=    # build with the host's tools
```

An empty `NODE_IMAGE` is the path for a machine where Node is already installed. With it,
dependencies stay in the source tree (`web-apps/build/node_modules` and
`web-apps/vendor/framework7-react/node_modules`) rather than in `CACHE_DIR`, so switching between
the two paths costs one reinstallation of dependencies.

### npm dependencies

They are installed twice: in `web-apps/build` and inside the grunt task for the mobile part
(`web-apps/vendor/framework7-react`, the `exec:webpack_install` task) — about 513 MB.

In a containerized build, both dependency directories live not in the source tree but in
`CACHE_DIR/node_modules/{web-apps-build,framework7-react}` and are mounted into the tree. This way
they survive the restoration of the tree and a fresh clone. The npm download cache is
`CACHE_DIR/npm`; the registry address comes from the `NPM_REGISTRY` pin (empty means the Node
image's default registry) and is passed to the container as `npm_config_registry`.

`CACHE_DIR` (by default `overlay/.cache`) can be deleted at any time: the next run installs the
dependencies again. This is exactly what to do when `NODE_IMAGE` moves to a different major Node
release — native modules built earlier may not work with it.

### Static files stamp

The input fingerprint consists of the checksum of `versions.env`, the revisions of the four clones
(`web-apps`, `sdkjs`, `sdkjs-forms`, `build_tools`), the mode `sdk-minify=<0|1>`, the pinned version
`terser=<version>`, the script checksum `minifier=<sha256 tools/sdk-minify.cjs>` and the
`--override` overrides, if any. The script stores it in `SOURCES_DIR/.static-stamp` (by default
`$FORK/.static-stamp`) and compares it on the next run: if the fingerprint matches and both
`deploy/` directories are in place, the build is skipped.

Overrides are part of the fingerprint because the file checksum does not see them: they are applied
on top of what was read, and `--override BUILD_NUMBER=…` changes the number baked into the static
files without changing the file itself. The pairs are sorted, so the order of the arguments does not
change the fingerprint.

```bash
bash "$FORK/overlay/build-static.sh"                   # "статика актуальна для …, сборка пропущена" ("static files are up to date for …, build skipped")
FORCE_STATIC=1 bash "$FORK/overlay/build-static.sh"    # rebuild unconditionally
```

The stamp is deleted **before** the first modifying operation and written only after success, so an
interrupted build does not look fresh. The `build_tools` revision is part of the fingerprint even
though the static files build itself does not touch this clone: `prepare.sh` executes its Python
code, and changing the revision changes what ends up in the image.

The static files stamp does not replace the checks in `prepare.sh`: the source tag, the
`build_tools` revision and the verification of `api.js.tpl` against the reference are always
performed, whether the static files build was skipped or not.

### The build modifies the working tree

This is the standard behavior of the official ONLYOFFICE pipeline: `merge_and_check.py` without
`--check` merges missing entries into the dictionaries (about 152 files `apps/**/locale/*.json`),
the `increment-build` task writes `build + 1` back to `build/<component>.json` (six files), and
webpack leaves untracked `apps/*/mobile/dist/` and `apps/*/mobile/index.html`.

Therefore, before each rebuild `build-static.sh` returns all three source clones to the state of the
tag:

```bash
git -C <source> checkout -- .
git -C <source> clean -fd -e node_modules
```

The input fingerprint does not see the state of the working tree, and it is this restoration, not
the stamp, that protects against building on top of stray changes. The dependency directories are
excluded from the cleanup — otherwise reusing them would be pointless. The `deploy/` directories are
not touched: they are listed in the sources' `.gitignore`, and the build itself overwrites them.

### Arguments and variables

| Argument | What it sets |
|---|---|
| `--override KEY=value` | build with a different pin; repeatable |
| `--release` | release build: checks of the release address and number before the build and in the built static files (section "Release build") |

This is also how `NODE_IMAGE` (the image for building the static files; empty means the host's
tools) and `NPM_REGISTRY` (the npm registry address; empty means the image's default registry) are
set: both come from `versions.env`, and an environment variable with that name does not affect them.

| Variable | What it sets |
|---|---|
| `FORCE_STATIC=1` | rebuild even if the fingerprint matches the stamp |
| `FORK_DIR` | the fork root for the default paths |
| `WEBAPPS_DIR`, `SDKJS_DIR`, `SDKJS_FORMS_DIR` | the source clones |
| `BUILD_TOOLS_DIR` | the build scripts clone; only its revision is needed, as part of the input fingerprint |
| `SOURCES_DIR` | the directory with `.static-stamp` and `.sdk-minify` (by default `FORK_DIR`); the same value for `build-static.sh`, `prepare.sh` and `build.sh` |
| `CACHE_DIR` | npm dependencies and the download cache (by default `overlay/.cache`) |

### Why grunt runs twice

The file `apps/common/main/resources/img/doc-formats/formats@2.5x.svg` is a sprite that the
`prebuild-icons-sprite` task generates **into the sources** (it is listed in `.gitignore`). The
`svgmin` task, which distributes the svg files into `deploy`, runs earlier, so on a clean clone the
first pass does not put the sprite into `deploy`, and the second one does. Rebuilding **only** the
`common` component (`npx grunt deploy-common-component`) instead of the second full pass does not
work: the substitution of `{{PRODUCT_VERSION}}`, `{{PUBLISHER_NAME}}` and other placeholders in the
shared files (`lib/view/About.js`, `lib/view/Header.js`, `lib/controller/Desktop.js`,
`lib/controller/External{Diagram,Merge,Ole}Editor.js`) is performed by the tasks of the editor
components, and after rebuilding `common` alone these six files keep their placeholders.

The script checks that this sprite is present in `deploy` after the build — together with two other
output files. The check is needed because grunt runs with `--force` and exits successfully even when
a task fails: the exit code is not enough here, the output itself has to be inspected.

### SDK minification

After building sdkjs and web-apps, before preparing the context and pre-compression, the build
minifies exactly six files: `sdk-all-min.js` and `sdk-all.js` in the word, cell and slide
directories. The file names are kept. `deploy/sdkjs/visio/sdk-all*.js` are not minified: Visio is
outside the tested scope of this step; api.js, embed, the PDF SDK, `.bin` files and the sources are
not changed either. Terser runs with `compress: false`, `mangle: false`; copyright and license
notices are preserved by the filter
`/@preserve|@license|@cc_on|^!|Copyright|GNU|Affero|AGPL|license|licence/i`. Before the results are
written, the number of occurrences of `/Copyright|Affero/gi` is checked separately for each file: a
decrease in even one of them stops the step without changing any of the six files.

The step uses Terser from `web-apps/build/node_modules`, installed by the standard `npm install`
from the existing `package-lock.json`. The step performs no separate package installation and no
network requests. An exact match with `TERSER_VERSION` from `versions.env` (currently `5.28.1`) is
required, not just any 5.x version. A missing Terser, a mismatching version, or a missing or empty
file among the six is an error raised before any of these files is changed. The script receives the
pinned version as its third argument:
`node tools/sdk-minify.cjs <sdkjs deploy dir> <web-apps build dir> <TERSER_VERSION>`. For a build
without network access, the web-apps dependencies must be available in advance in
`CACHE_DIR/node_modules/web-apps-build` and in the npm cache; populating the cache itself remains
part of preparing a regular build environment.

The mode `SDK_MINIFY=1` and the version `TERSER_VERSION=5.28.1` are keys in `versions.env`, like the
other build pins. A mode outside `0|1` or a version not of the form `5.<number>.<number>` is
rejected. Environment variables of the same name do not change the values. A deviation is set only
with an explicit `--override`; to disable minification and then build the image:

```bash
bash "$FORK/overlay/build-static.sh" --override SDK_MINIFY=0
bash "$FORK/overlay/build.sh" --override SDK_MINIFY=0
```

A rerun without the override returns to the mode from the file. A permanent change of the mode or of
the pinned version is made by editing `versions.env`.

The actual Terser version is printed as the line `sdk-minify: terser=<version>` and saved together
with the mode in `$SOURCES_DIR/.sdk-minify`: `SDK_MINIFY=1`, `SDK_MINIFY_TERSER=<version>`; when
disabled — `SDK_MINIFY=0`, `SDK_MINIFY_TERSER=none`. The file contains only these two keys; the
pairs `0/version` and `1/none`, an incomplete file and an extra key are rejected. The mode and
version of the artifact must match the current pins, taking `--override` into account: for example,
a mode `0` artifact is not accepted when mode `1` is selected. After changing the pins, rebuild the
static files first.

By default `SOURCES_DIR` equals `FORK_DIR`; with a different path, pass the same value to
`build-static.sh`, `prepare.sh` and `build.sh`. The mode and the actual version go into the context
stamp and into the separate image labels `overlay.sdk-minify.mode=<0|1>` and
`overlay.sdk-minify.terser=<version|none>`.

The mode, the pinned version and the checksum of the minification script are part of the static
files fingerprint: a previous build with different values is not considered up to date. Rolling back
a finished image requires a full rebuild with `--override SDK_MINIFY=0` or a committed change to
`versions.env`; changing a variable at DS startup does not change its SDK. The pre-compressed copies
and the static files version are produced by the subsequent standard steps from the resulting
content. The x2t cache must be created from the SDK of the same image; the cache of a previous image
cannot be considered compatible without a separate check.

After minification, individual lines reach about 680 KB: line numbers in a stack trace barely help
to locate an error; the analysis must also take the position within the line into account.

The public overlay snapshot contains 13 files: the previous 12 and `tools/sdk-minify.cjs`. This is
intentional: the script is needed to build the shipped static files and is part of the Corresponding
Source. A snapshot without it does not contain the complete recipe for this build.

## Post-processing and verification: prepare.sh

The grunt output is not yet what is in the image. The official Document Server packaging performs
four steps on the static files that are not part of the JS build (found in
`build_tools/scripts/deploy_server.py`):

1. **Embed worker.** `deploy_server.py:132` runs `sdkjs/common/embed/make.py` on
   `web-apps/apps/api/documents/api.js` — the script embeds the minified `embed.min.js` into it (the
   `AscEmbedGlobalScroller` class and the `createEmbedWorker` method). Without this step the embed
   mode of the editors breaks.
2. **Cache version.** The source `apps/api/documents/api.js` hardcodes `var params = "?_dc=0"`,
   while the image has `"?_dc=9.4.0-129"`. This substitution is made by the
   `document-server-package` packaging; it is in neither `build_tools` nor the deb package's
   postinst.
3. **Removal of `*.js.map`** — `deploy_server.py:124-126`.
4. **Renaming to `api.js.tpl`.** The image contains precisely the template: at every container start
   `documentserver-flush-cache.sh` runs `cp api.js.tpl api.js` and substitutes `{{HASH_POSTFIX}}`
   into it. If `api.js` were put into the image, the container start would overwrite it with the
   template from the base image — and our version would never reach the browser.

`prepare.sh` performs all four steps. It assembles the context directory
`overlay/context/{sdkjs,web-apps}`, sets permissions as in the image (directories `0555`, files
`0444`) and **verifies** the resulting `api.js.tpl` against the reference from the official image
(`REFERENCE_TPL`, by default `_ref/image/web-apps/apps/api/documents/api.js.tpl`). A match is
printed as the line `СВЕРКА: api.js.tpl побайтово совпал с эталоном образа (<sha256>)`
("VERIFICATION: api.js.tpl matched the image reference byte for byte (<sha256>)"); if the bytes do
not match, the script fails. The match is the proof that the post-processing has been reproduced
correctly.

```bash
bash "$FORK/overlay/prepare.sh"
```

It is usually not run separately: `build.sh` calls it. The script is idempotent: the context is
recreated from scratch on every run. The version, the build number, the source tag and the
`build_tools` revision come from the pins; the source directories, the reference and the context
directory are set by environment variables — `WEBAPPS_DIR`, `SDKJS_DIR`, `SDKJS_FORMS_DIR`,
`BUILD_TOOLS_DIR`, `REFERENCE_TPL`, `CONTEXT_DIR`.

**The context is never partial.** Everything is assembled in `overlay/context.tmp`, and the last
command renames this directory to `context`. An interrupted preparation leaves `context.tmp` behind
— the next run deletes it — and the `context` directory never exists in an incomplete state, not
even for a moment.

**Readiness stamp.** Before the rename, `context/.overlay-stamp` is written to the context root:
nine `KEY=value` lines — `SOURCE_TAG`, `WEB_APPS_REV`, `SDKJS_REV`, `SDKJS_FORMS_REV`,
`BUILD_TOOLS_REV`, `API_TPL_SHA256`, `SDK_MINIFY`, `SDK_MINIFY_TERSER`, `PREPARED_AT`. `build.sh`
takes the image labels from it; `build.sh` refuses to build a context without the stamp. The stamp
does not get into the image: the `Dockerfile` copies only `context/sdkjs/` and `context/web-apps/`.

Before copying, the preconditions are checked: the format of `PRODUCT_VERSION` and `BUILD_NUMBER`
(they are substituted into a `sed` expression), the revision and working tree cleanliness of
`build_tools`, the tags of the source clones, the presence of `embed.min.js` and of the reference,
and that `CONTEXT_DIR` lies inside the overlay directory and ends with `context` — this directory is
deleted recursively. With an empty `EXPECTED_API_TPL_SHA256`, verification against the reference is
mandatory: an unavailable reference is an error, not a skip. The verification can be skipped only
explicitly, with the `--allow-no-reference` argument — a warning then goes to the log. `prepare.sh`
does not read an environment variable with this name at all.

**Source tags.** In each of `web-apps`, `sdkjs`, `sdkjs-forms`, HEAD must carry the tag from the
`SOURCE_TAG` pin — this is checked against the list of tags on HEAD, not via `git describe`. The
context is assembled precisely from the `deploy/` directories of these clones, so a build from some
other commit stops before copying, reporting the actual HEAD and a `git checkout` hint. A deliberate
build from a different tag is done with `--override SOURCE_TAG=<tag>`. There must be no tracked
changes in the clones either, but `prepare.sh` has no such check: full coverage is provided by
`compare.sh`.

**Derived paths are not set separately.** The script derives the `deploy/`, `common/embed` and
`scripts/` directories from the source directories and rejects directly set `SDKJS_DEPLOY`,
`WEBAPPS_DEPLOY`, `EMBED_DIR` and `BUILD_TOOLS_SCRIPTS` with an error: otherwise the tag and
revision would be checked on one directory while the content of another would end up in the image.

**Fork changes and verification.** By default `EXPECTED_API_TPL_SHA256` in `versions.env` is empty:
the result must match the reference from the official image. If a change touches
`web-apps/apps/api/documents/api.js` or `sdkjs/common/embed/embed.min.js`, the SHA-256 of the
checked final `api.js.tpl` is pinned in `EXPECTED_API_TPL_SHA256` together with it. This is the hash
of the result after the version substitution and the worker embedding, not of the source `api.js`. A
non-empty value must consist of 64 lowercase hexadecimal characters; a mismatch stops the build
regardless of whether the official reference is available and of `--allow-no-reference`. The source
tags and the `build_tools` revision are checked in both modes. Accepting the actual hash on your own
after a failed verification is not allowed: the sources and the post-processing are checked first.
`--allow-no-reference` remains only a workaround for a missing reference when the pin is empty.

**How to delete the context.** Permissions in `overlay/context` are set as in the image (directories
`0555`, files `0444`), and deleting a file requires write permission on its directory — so a plain
`rm -rf` fails with `Permission denied` even for the owner. Free these 954 MB like this:

```bash
chmod -R u+w "$FORK/overlay/context" && rm -rf "$FORK/overlay/context"
chmod -R u+w "$FORK/overlay/context.tmp" && rm -rf "$FORK/overlay/context.tmp"   # after an interrupted preparation
```

## Building the image

```bash
bash "$FORK/overlay/build.sh"                       # tag 9.4.0.1-local
bash "$FORK/overlay/build.sh" 9.4.0.1-local-probe   # custom tag
bash "$FORK/overlay/build.sh" --release 9.4.0.1-b24.N \
  --override SOURCE_URL=<tag URL>                   # release, section "Release build"
bash "$FORK/overlay/build.sh" --help                # help
```

`build.sh` calls `prepare.sh`, then `docker build`, and prints the name, Image ID, size and all
labels of the image. The default tag is `<IMAGE_TAG_BASE>-local`; the default name is
`localhost/documentserver-overlay:9.4.0.1-local`. The help and the tag format check
(`^[A-Za-z0-9][A-Za-z0-9._-]*$`) run **before** the context is prepared: a typo in an argument costs
seconds, not minutes of copying.

The script has no pins of its own: the base image, the image repository and the base version come
from `versions.env`; the clone revisions and the `api.js.tpl` checksum come from the context
readiness stamp. The script takes the revision of overlay itself for the label from `OVERLAY_COMMIT`
if it is set, otherwise from its own git repository, but only when the overlay directory is the root
of that repository; otherwise it writes `unknown`: a snapshot without `.git` unpacked inside another
repository does not get the revision of unrelated code. For a build from such a snapshot, set
`OVERLAY_COMMIT` to the SHA of the overlay commit the snapshot was made from.

The `Dockerfile` is structured as follows: `ARG BASE_IMAGE` → `FROM ${BASE_IMAGE}`, then two
`COPY --chown=ds:ds` on top of `/var/www/onlyoffice/documentserver/{sdkjs,web-apps}`. This is an
**overlay**: the base image directories are not deleted, so files absent from the JS build remain in
place — above all `sdkjs/*/sdk-all.bin` (the js-cache of the x2t engine), and next to them
`sdkjs-plugins`, `fonts`, `core-fonts`, `dictionaries`, `server`, `npm`, `document-formats`,
`document-templates` remain untouched. The next layer deletes `*.gz` under the overlaid trees: at
startup `documentserver-static-gzip.sh` recompresses the static files, but until then nginx with
`gzip_static on` would serve compressed copies of the old static files. The `9.4.0.1` base image has
no such files — the command is a safeguard in case of a different base image. After it, the
compression layer installs the nginx module `brotli_static`, creates brotli copies of the static
files and enables serving them (section "Brotli compression"). After that nothing changes the static
files: the static files version wrapper is installed into `/usr/local/bin`, and the rest is `ENV`,
`ARG` and `LABEL`, so editing them does not rebuild the compression layer.

`ARG` and `LABEL` come **after** both `COPY` instructions: otherwise a change of the tag or revision
would invalidate the cache of the two overlay layers totaling 953 MB. The order is checked like this
— both `COPY` lines must be below `LABEL` in the output (it goes from the newest layer to the
oldest):

```bash
docker image history <image> --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' | head
```

`ARG BASE_IMAGE` intentionally has no default value: the only source of the base is `versions.env`,
and a direct `docker build` without `--build-arg BASE_IMAGE=…` must fail immediately rather than
silently use an outdated base. A reference without `@sha256:` builds but provides no pin: `build.sh`
prints a warning, and the `base.digest` label stays `unknown`.

**Image labels.** Overlay sets seventeen labels, and together they describe exactly what the image
is built from (`docker image inspect <image> --format '{{json .Config.Labels}}'`):

| Label | Value |
|---|---|
| `org.opencontainers.image.base.name` | the base image from the pins, together with `@sha256:` |
| `org.opencontainers.image.base.digest` | the base digest as a separate value, otherwise `unknown` |
| `org.opencontainers.image.version` | the tag of the image being built |
| `org.opencontainers.image.ref.name` | the full name of the built image, `IMAGE_REPO:<tag>` |
| `org.opencontainers.image.revision` | the SHA of the overlay commit |
| `org.opencontainers.image.created` | the build time, UTC |
| `org.opencontainers.image.licenses` | `AGPL-3.0-only` |
| `org.opencontainers.image.title` | the image name |
| `org.opencontainers.image.description` | what the image is built from, in one line |
| `overlay.source-tag` | the source tag from the stamp |
| `overlay.web-apps.revision` | the `web-apps` commit from the stamp |
| `overlay.sdkjs.revision` | the `sdkjs` commit from the stamp |
| `overlay.sdkjs-forms.revision` | the `sdkjs-forms` commit from the stamp |
| `overlay.build-tools.revision` | the `build_tools` commit from the stamp |
| `overlay.api-tpl.sha256` | the sha256 of the post-processed `api.js.tpl` |
| `overlay.sdk-minify.mode` | the SDK minification mode: `0` or `1` |
| `overlay.sdk-minify.terser` | the actual Terser version; `none` in mode `0` |

The `overlay.api-tpl.sha256` label is useful for investigation: it lets you confirm that an image
built anywhere carries the same `api.js.tpl` that passed verification against the reference.

An image built in release mode carries an eighteenth label — `overlay.release` with the value of
`SOURCE_TAG` (section "Release build"). Without release mode the image has no such label.

The build context is `overlay/context` and the `documentserver-flush-cache.sh` wrapper
(`.dockerignore` excludes the rest), about 950 MB.

### Brotli compression

To a client whose `Accept-Encoding` includes `br`, the image serves the editor static files as
brotli copies compressed at build time (`Content-Encoding: br`); other clients get `.gz` as before.
On these static files brotli `-q 11` output is smaller than gzip `-9`, which the container uses at
startup: by 27% for `sdk-all-min.js` and by 30% for `sdk-all.js`, and a cold editor load (the
first one after rolling out an image with new static files, or in a new browser profile)
transfers 2–2.5 MB less. Loads from the browser cache are unchanged.

The copies are made by a `Dockerfile` layer right after `*.gz` is deleted: `<file>.br` next to the
file, with the same owner, permissions and modification time. The same selection is compressed that
the image's `documentserver-static-gzip.sh` compresses to `.gz` at startup (`*.js`, `*.json`,
`*.htm`, `*.html`, `*.css`, `*.bin`, `*.wasm`, `*.dic`, `*.aff`, `*.svg`), but only in `sdkjs`,
`web-apps` and `dictionaries`, and only what does not change after the build: nginx serves the `.br`
without checking it against the file, while startup recreates only `.gz`. Therefore the files
written at startup have no `.br` — `api.js` (rendered from `api.js.tpl`),
`sdkjs/common/AllFonts.js`, `sdkjs/common/Images`, `sdkjs/slide/themes`, the x2t js-caches
`sdk-all.bin` and `sdk-all.cache` — and neither do `fonts` and `sdkjs-plugins`. For them, as before,
the `.gz` files created at startup are served.

For the same reason, an individual static file must not be replaced on top of a finished image (by
mounting, `docker cp`) without its `.br`: nginx would serve clients with `br` the old content from
the image, while the static files version would change, and the browser would store the old body
under the new version. Static files are changed with a new image; a replaced file needs its own
`.br`, or the old `.br` must be removed.

The module is the Ubuntu package `libnginx-mod-http-brotli-static` (ngx_brotli, BSD-2-Clause) from
the base image's release. It depends on the ABI of the installed nginx, so apt installs only a
compatible build, and the step checks that this nginx loads the module. The `brotli` utility is
needed only for compression and does not get into the image; the step neither upgrades nor removes
other base packages — it compares their list before and after. The `brotli_static on` directive is
placed on a separate line after `gzip_static` in three static locations of `ds-docservice.conf`: the
service worker, `*.json` from `web-apps` and the general static location. It is absent from the
`api.js` location. The `Cache-Control` of the responses is unchanged, and `br` responses also have
`Vary: Accept-Encoding`.

The step accesses the Ubuntu package archive (section "Environment requirements") and stops if any
of its apt sources is unavailable. It compresses about 625 MB of static files at level 11 — several
minutes on a multi-core machine — and adds about 100 MB to the image. The `.br` files are not part
of the static files version (section "Static files version").

A check on a container started as in section "Running the built image":

```bash
docker exec documentserver ls -l /var/www/onlyoffice/documentserver/sdkjs/word/sdk-all-min.js.br
V=$(docker exec documentserver sed -n 's/.*"\(.*\)";/\1/p' /etc/nginx/includes/ds-cache.conf)
curl -s -o /dev/null -D - -H 'Accept-Encoding: gzip, deflate, br' \
  "http://localhost:8080/9.4.0-$V/sdkjs/word/sdk-all-min.js" | grep -i -E '^(content-encoding|vary)'
# content-encoding: br and vary: Accept-Encoding; with 'Accept-Encoding: gzip' — gzip
```

### Static files version

Editor static file URLs contain a version: `/9.4.0-<version>/web-apps/…`,
`/9.4.0-<version>/sdkjs/…`, `/9.4.0-<version>/fonts/…`. It is chosen by
`documentserver-flush-cache.sh` at container start and after fonts are regenerated, and the browser
(the HTTP cache and the editor's service worker) keys its static files cache by it. The base image's
script derives the version from the current date and minute, so every start and every node produce
their own version for the same files, and the browser downloads the editor again.

The image installs the wrapper `/usr/local/bin/documentserver-flush-cache.sh` (it comes before
`/usr/bin` in `PATH`): the version is the md5 of the content of the served directories `web-apps`,
`sdkjs`, `sdkjs-plugins`, `fonts`, `dictionaries` — only of world-readable files (those are the ones
nginx can serve), excluding the compressed `.gz` and `.br` copies (their content is the same files),
`api.js` and the x2t js-caches `sdk-all.bin`, `sdk-all.cache` (they are recreated at startup and
differ every time). The `0600` temporary files that `allthemesgen` leaves under random names in the
theme directory at every start therefore do not affect the version. The same image, fonts and
plugins yield the same version on all nodes and after a restart; changing the image, fonts or
plugins changes the version. With `PLUGINS_ENABLED=true` the plugin manager runs in the background
at startup; if it has not finished yet, the wrapper recomputes the version once it completes and
reloads nginx — otherwise updated plugins would be served under a version computed before the
update. In the image the manager does not run by default (section "Plugins"), and the version is
computed once per call. The computation takes a few seconds per call (two or three per start). An
explicit `-h <version>` is passed by the wrapper to the image's script unchanged; if the
content-based version could not be computed, the time-based version remains.

A check on a running container — the version is the same before and after `docker restart`:

```bash
docker exec documentserver cat /etc/nginx/includes/ds-cache.conf   # set $cache_tag "<version>";
```

### Plugins

By default, plugin loading is disabled in the image: the `Dockerfile` sets
`ENV PLUGINS_ENABLED=false`. With `PLUGINS_ENABLED=true` (its own default), the base image's startup
script runs the plugin manager in the background, which downloads the latest plugin release from the
list `sdkjs-plugins/plugin-list-default.json`. With `false`, nothing is downloaded at startup, and
`sdkjs-plugins` contains only the base image files: `marketplace/`, `v1/`, `pluginBase.js`,
`plugins.css`, `plugin-list-default.json` and the compressed `.gz` copies created at startup. The
switch disables only the download on the node. The "Plugin Manager" in the editor (`marketplace/`)
remains available and lets a user install a plugin from the network into their browser unless the
integrator sets `customization.plugins=false`.

To enable the download, use `-e PLUGINS_ENABLED=true` for `docker run`, or the same variable in the
orchestrator job's environment or in the compose `environment`: the container's environment variable
takes precedence over the image's `ENV`. The cost: at every start the manager downloads the latest
plugin release from the network without a pinned version or checksum, so nodes started at different
times get different plugins and a different static files version (section "Static files version").
Whether plugins are shown in the editor is also decided by the integrator — with the editor config
parameter `customization.plugins`.

A check on the image and on a container started as in section "Running the built image":

```bash
docker image inspect localhost/documentserver-overlay:<tag> --format '{{json .Config.Env}}'   # contains "PLUGINS_ENABLED=false"
docker exec documentserver ls /var/www/onlyoffice/documentserver/sdkjs-plugins
# marketplace  plugin-list-default.json  pluginBase.js  plugins.css  v1
# Compressed .gz copies created at container start are also acceptable.
docker logs documentserver 2>&1 | grep -c 'Plugins initialization finished'   # 0
```

With `-e PLUGINS_ENABLED=true` the last command returns `1`: the line
`[pluginsmanager] Plugins initialization finished` appears in the log, and with network access the
directories of the downloaded plugins appear in `sdkjs-plugins`.

### Release build

A release is an image whose "About" window names the release number and the address of its source
code (section "Why the v9.4.0.129 tag"). Such an image is built by both scripts with the `--release`
flag, on source clones at `SOURCE_TAG`, and with the same address:

```bash
SOURCE_URL=<SOURCE_TAG tag page in the overlay repository>   # ends with /<SOURCE_TAG>
bash "$FORK/overlay/build-static.sh" --release --override SOURCE_URL="$SOURCE_URL"
bash "$FORK/overlay/build.sh" --release --override SOURCE_URL="$SOURCE_URL" 9.4.0.1-b24.N
```

When the real address is recorded in `versions.env`, the `--override SOURCE_URL=…` argument is not
needed. The release image tag is `<IMAGE_TAG_BASE>-b24.N` with the same `N` as in `SOURCE_TAG`; it
is set by the `build.sh` argument.

**Before the build**, both scripts check the pins — before the directory checks, context
preparation and the first docker call:

- `SOURCE_TAG` is a release tag of the form `v<PRODUCT_VERSION>.<BUILD_NUMBER>-b24.N` with `N` from
  1, currently `v9.4.0.129-b24.N`: image promotion later expects the same label;
- `SOURCE_URL` starts with `https://`, has a non-empty host, is not a placeholder in the `.invalid`
  domain, has no query (`?`) and no fragment (`#`), ends with `/<SOURCE_TAG>` and consists only of
  the characters `A–Z a–z 0–9 . _ ~ : / @ % + = & -`: the address goes into a JavaScript string
  literal and into the window markup, so quotes, backslashes, spaces and angle brackets are not
  allowed in it.

Each mismatch is printed as a line starting with `ОШИБКА:` ("ERROR:") with the key name, and the
script exits with code 1.

**After the build**, the `web-apps` static files themselves are checked: `build-static.sh` checks
the `web-apps/deploy/web-apps` directory, including when the build is skipped by the stamp;
`build.sh` checks the static files in the image context, after making sure that the context was
built from the `SOURCE_TAG` tag. The "About" window of each editor must contain both the address and
the release number in a single `*.js` file; the number as a separate quoted string, not only as the
end of the address:

- the desktop versions of `documenteditor`, `spreadsheeteditor`, `presentationeditor`, `pdfeditor`,
  `visioeditor` are not bundled into a single package and include the shared window — the
  `common/main/lib/view/About` module, a single file `apps/common/main/lib/view/About.js` in the
  static files (the same as in the official image). The address and the number are checked in it;
  the `apps/<editor>/main` directory must exist for each of the five, and an editor that does not
  include the shared module must carry the address and the number in its own directory;
- the mobile versions of all editors except `pdfeditor` are built as bundles — the address and the
  number are looked for in the `apps/<editor>/mobile` directory.

No `*.js` or `*.json` file under `apps/` may contain the unsubstituted placeholders
`{{SOURCE_URL}}`, `{{RELEASE_VERSION}}` or the former link placeholder `Source code: [link]` or
`Исходный код: [ссылка]` (its Russian form). A rejection lists every directory and file where
something is wrong; on rejection, the stamp of freshly rebuilt static files is not written.

Only when the checks pass does `build.sh` set the `overlay.release=<SOURCE_TAG>` label on the image.
It shows that the image was built in release mode and for which release exactly: an image without
this label or with the label of another release is not considered a release.

## Equivalence check

`compare.sh` compares the built static files (`sdkjs/deploy/sdkjs`, `web-apps/deploy/web-apps`) with
the reference from the base image by the sha256 of each file and sorts the differences into
categories. The reference is the whole `_ref/image` directory; how to obtain it is described in
section "Local _ref directory". For the equivalence check, build the static files with minification
disabled:

```bash
bash "$FORK/overlay/build-static.sh" --override SDK_MINIFY=0
```

In mode `1`, the six files `sdkjs/{word,cell,slide}/sdk-all{,-min}.js` intentionally differ from the
reference; these differences do not indicate a packaging error. The description of the differences
below applies to mode `0`.

```bash
bash "$FORK/overlay/compare.sh"                                          # the root is the directory above overlay
bash "$FORK/overlay/compare.sh" --root "$FORK" --reference "$FORK/_ref/image"
bash "$FORK/overlay/compare.sh" --root "$FORK" --reference "$FORK/_ref/image" --json report.json
```

`--root` is the fork root with the clones (by default the directory above overlay), `--reference` is
the reference directory (by default `<root>/_ref/image`), `--json` is the path of the report file.

For static files built from unmodified sources (`v9.4.0.129`) there are no content differences. Only
the set of files differs, and this is expected: `sdkjs/*/sdk-all.bin` exists only in the image (the
x2t js-cache, built outside the JS build), `*.js.map` exists only in the build (the official
packaging deletes them — `prepare.sh` does this), some of the `apps/*/mobile/css/*.css` files in the
image are leftover artifacts of earlier builds that nothing references, plus the `api.js` ↔
`api.js.tpl` pair. Files created at container start (`AllFonts.js`, font and theme previews) are
absent from the reference extracted without a start. With the fork's static files, exactly the
`web-apps` files modified by the fork's changes are added to this.

## Running the built image

The image runs like the official Document Server, with the standard environment variables and
directories:

```bash
docker run -d --name documentserver \
  -p 8080:80 \
  -e JWT_ENABLED=true -e JWT_SECRET=<secret> \
  -v <data>:/var/www/onlyoffice/Data \
  -v <logs>:/var/log/onlyoffice \
  localhost/documentserver-overlay:<tag>

curl http://localhost:8080/healthcheck      # response: true
```

`<tag>` is the tag `build.sh` built with (by default `9.4.0.1-local`). The name
`localhost/documentserver-overlay` is local only: docker will not pull it from Docker Hub, and
without a built image `docker run` fails with an error rather than starting someone else's image.
`JWT_SECRET` is the secret with which the integrating application signs requests to Document Server;
with `JWT_ENABLED=false` the service would accept unsigned requests from anyone. `<data>` and
`<logs>` are host directories for the service's data and logs.

The first start takes several minutes: `AllFonts.js` and the font previews are generated and the
static files are recompressed; until then `/healthcheck` does not return `true`. What is worth
checking inside the container:

```bash
D=/var/www/onlyoffice/documentserver
docker exec documentserver ls -l $D/sdkjs/common/AllFonts.js                   # non-empty
docker exec documentserver grep -c '_dc=9.4.0-129' $D/web-apps/apps/api/documents/api.js
docker exec documentserver grep -c '{{HASH_POSTFIX}}' $D/web-apps/apps/api/documents/api.js   # 0
docker exec documentserver ls -l $D/sdkjs/word/sdk-all-min.js.gz               # gz recreated
docker exec documentserver ls -l $D/sdkjs/word/sdk-all-min.js.br               # br from the image build
docker exec documentserver ls -l $D/sdkjs/word/sdk-all.bin                     # from the base image
curl -s http://localhost:8080/web-apps/apps/api/documents/api.js | grep -c AscEmbedGlobalScroller
```

To stop and remove the container: `docker rm -f documentserver`.

## License

The code of this repository is distributed under the terms of the GNU Affero General Public License
version 3 (`AGPL-3.0-only`); the full text is in the `LICENSE` file, and the same license is stated
by the image's `org.opencontainers.image.licenses` label. The sources of the static files — the
forks of ONLYOFFICE `web-apps`, `sdkjs` and `sdkjs-forms` at the `SOURCE_TAG` tag — are distributed
under the terms of their own licenses. The binary part of the image (server, x2t, fonts,
dictionaries) has not been modified and is taken from the official ONLYOFFICE image
`onlyoffice/documentserver` of this version, pinned in `BASE_IMAGE`. The image contains no plugins;
the "Plugin Manager" is taken from the base image unchanged. The nginx module `brotli_static` is the
Ubuntu package `libnginx-mod-http-brotli-static` (ngx_brotli), distributed under the terms of
BSD-2-Clause.
