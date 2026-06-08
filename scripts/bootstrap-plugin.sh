#!/usr/bin/env bash
# Rename template identifiers when starting a new plugin from magenta-au-template.
#
# Usage:
#   ./scripts/bootstrap-plugin.sh \
#     --name "My Plugin" \
#     --slug my-plugin \
#     --prefix MYPL \
#     --state-prefix MYPL_ \
#     --bundle-id com.example.myplugin \
#     --dev-port 62423
#
# Dry run:
#   ./scripts/bootstrap-plugin.sh --dry-run --name "My Plugin" ...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=false
PLUGIN_NAME=""
SLUG=""
AU_SUBTYPE=""
STATE_PREFIX=""
BUNDLE_ID=""
DEV_PORT="62423"

usage() {
  sed -n '1,18p' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)         PLUGIN_NAME="$2"; shift 2 ;;
    --slug)         SLUG="$2"; shift 2 ;;
    --prefix)       AU_SUBTYPE="$2"; shift 2 ;;
    --state-prefix) STATE_PREFIX="$2"; shift 2 ;;
    --bundle-id)    BUNDLE_ID="$2"; shift 2 ;;
    --dev-port)     DEV_PORT="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [ -z "$PLUGIN_NAME" ] || [ -z "$SLUG" ] || [ -z "$AU_SUBTYPE" ] || [ -z "$STATE_PREFIX" ] || [ -z "$BUNDLE_ID" ]; then
  echo "Error: --name, --slug, --prefix (4-char AU subtype), --state-prefix, and --bundle-id are required." >&2
  usage 1
fi

if [ "${#AU_SUBTYPE}" -ne 4 ]; then
  echo "Error: AU subtype (--prefix) must be exactly 4 ASCII characters (e.g. MYPL)." >&2
  exit 1
fi

HOST_APP="${PLUGIN_NAME} (AU).app"
PKG_ID="${BUNDLE_ID}.installer"
ARTIFACT_PREFIX="$(echo "$SLUG" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

run_sed() {
  local file="$1"
  shift
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] would patch: $file"
    return
  fi
  sed -i '' "$@" "$file"
}

echo "Bootstrapping plugin:"
echo "  Display name:  $PLUGIN_NAME"
echo "  Host app:      $HOST_APP"
echo "  AU subtype:    $AU_SUBTYPE"
echo "  State prefix:  $STATE_PREFIX"
echo "  Bundle ID:     $BUNDLE_ID"
echo "  Dev port:      $DEV_PORT"

FILES=(
  CMakeLists.txt
  Info.plist.in
  HostInfo.plist.in
  MagentaAU_AudioUnit.mm
  MagentaAU_ViewController.mm
  MagentaAU_HostApp.mm
  scripts/build-installer-pkg.sh
  scripts/pkg-postinstall
  scripts/ci-reclaim-disk.sh
  README.md
  INSTALL.md
  AGENTS.md
)

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  run_sed "$f" \
    -e "s/Magenta AU Template/${PLUGIN_NAME}/g" \
    -e "s/Magenta-AU-Template/${SLUG}/g" \
    -e "s/magenta-au-template/${SLUG}/g" \
    -e "s/com\.audiohacking\.magenta\.template\.au\.host/${BUNDLE_ID}.host/g" \
    -e "s/com\.audiohacking\.magenta\.template\.au/${BUNDLE_ID}/g" \
    -e "s/MGTP/${AU_SUBTYPE}/g" \
    -e "s/MGTAU_/${STATE_PREFIX}/g" \
    -e "s/62422/${DEV_PORT}/g"
done

if [ "$DRY_RUN" = false ]; then
  echo ""
  echo "Done. Next steps:"
  echo "  1. Rename MagentaAU_* source files if desired (optional — update CMakeLists.txt)"
  echo "  2. Update Info.plist.in component name/description"
  echo "  3. Customize ui-patches/App.tsx"
  echo "  4. rm -rf build && cmake . -B build && cmake --build build --target deploy_magenta_au"
  echo "  5. auvaltool -v aumu ${AU_SUBTYPE} AHck"
fi
