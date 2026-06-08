#!/usr/bin/env bash
# RecipeBook-Modern CI — config, release resolution, export, deploy, site build.
# Usage: bash ci/run.sh <command>
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RBM_ROOT="$(cd "$CI_DIR/.." && pwd)"

# --- GitHub semver release resolution ---

github_repo_git_url() {
  local spec="${1:?repo required}"
  if [[ "$spec" == https://* ]]; then
    echo "$spec"
    return 0
  fi
  echo "https://github.com/${spec}.git"
}

_semver_strip() {
  echo "${1#v}"
}

_semver_gt() {
  local a b a1 a2 a3 b1 b2 b3
  a="$(_semver_strip "$1")"
  b="$(_semver_strip "$2")"
  IFS=. read -r a1 a2 a3 <<< "$a"
  IFS=. read -r b1 b2 b3 <<< "$b"
  a1=${a1:-0}
  a2=${a2:-0}
  a3=${a3:-0}
  b1=${b1:-0}
  b2=${b2:-0}
  b3=${b3:-0}
  (( a1 > b1 )) && return 0
  (( a1 < b1 )) && return 1
  (( a2 > b2 )) && return 0
  (( a2 < b2 )) && return 1
  (( a3 > b3 )) && return 0
  return 1
}

resolve_latest_semver_release_tag() {
  local repo_spec="${1:?owner/name or git URL required}"
  local git_url best tag

  git_url="$(github_repo_git_url "$repo_spec")"
  best=""
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    if [[ -z "$best" ]] || _semver_gt "$tag" "$best"; then
      best="$tag"
    fi
  done < <(
    git ls-remote --tags "$git_url" \
      | awk -F/ '{print $NF}' \
      | sed 's/\^{}//' \
      | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$'
  )

  if [[ -z "$best" ]]; then
    echo "error: no semver release tags found on ${git_url}" >&2
    return 1
  fi
  echo "$best"
}

resolve_github_release_ref() {
  local repo_spec="${1:?repo required}"
  local pinned="${2:-}"
  if [[ -n "$pinned" ]]; then
    echo "$pinned"
    return 0
  fi
  resolve_latest_semver_release_tag "$repo_spec"
}

resolve_github_release_version() {
  local ref
  ref="$(resolve_github_release_ref "$@")" || return 1
  echo "${ref#v}"
}

resolve_modpack_tag() {
  resolve_github_release_ref \
    "${MODPACK_REPO:-https://github.com/TerraFirmaGreg-Team/Modpack-Modern.git}" \
    "${MODPACK_TAG:-}"
}

resolve_mwe_tag() {
  resolve_github_release_ref \
    "${MWE_REPO:-jmecn/minecraft-web-export}" \
    "${MWE_TAG:-${MWE_VERSION:-}}"
}

resolve_site_viewer_version() {
  resolve_github_release_version \
    "${SITE_VIEWER_REPO:-jmecn/TFG-Recipe-Viewer-React}" \
    "${SITE_VIEWER_VER:-${SITE_VIEWER_VERSION:-}}"
}

resolve_renderer_version() {
  resolve_github_release_version \
    "${RENDERER_REPO:-jmecn/emi-recipe-renderer}" \
    "${RENDERER_VER:-${RENDERER_VERSION:-}}"
}

resolve_optimize_version() {
  resolve_github_release_version \
    "${OPTIMIZE_REPO:-jmecn/emi-bundle-optimize}" \
    "${OPTIMIZE_VER:-${OPTIMIZE_VERSION:-}}"
}

resolve_hmc_version() {
  resolve_github_release_version \
    "${HMC_REPO:-3arthqu4ke/headlessmc}" \
    "${HMC_VER:-${HMC_VERSION:-}}"
}

# --- Config ---

load_config() {
  local env_file="${CI_BUILD_ENV:-$CI_DIR/build.env}"
  if [[ ! -f "$env_file" ]]; then
    echo "::error::Missing CI config: $env_file" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  local ws="${GITHUB_WORKSPACE:-$RBM_ROOT}"
  EXPORT_RAW="${ws}/${EXPORT_RAW_DIR:-export-raw}"
  EXPORT_BUNDLE="${EXPORT_RAW}/${EXPORT_BUNDLE_SUBDIR:-emi}"
  EXPORT_OPT_STAGING="${ws}/${EXPORT_OPT_DIR:-export-opt}"
  SITE_OUTPUT_DIR="${SITE_OUTPUT_DIR:-site}"
  RUNNER_HOME="${RUNNER_HOME:-${HOME:-/home/runner}}"

  export RUNNER_HOME JAVA_VERSION NODE_VERSION
  export MC_VERSION MC_ASSET_INDEX FORGE_BUILD
  export HMC_REPO HMC_VERSION MODPACK_DIR MODPACK_REPO
  export MWE_REPO MWE_VERSION
  export SITE_VIEWER_REPO SITE_VIEWER_VERSION
  export RENDERER_REPO RENDERER_VERSION OPTIMIZE_REPO OPTIMIZE_VERSION
  export EXPORT_WARMUP_TICKS EXPORT_TIMEOUT_SECONDS
  export EXPORT_RAW EXPORT_BUNDLE EXPORT_OPT_STAGING
  export EXPORT_RAW_DIR EXPORT_BUNDLE_SUBDIR EXPORT_OPT_DIR SITE_OUTPUT_DIR
  export EXPORT_ARTIFACT_NAME="${EXPORT_ARTIFACT_NAME:-recipe-book}"
  export EXPORT_WORKFLOW_NAME="${EXPORT_WORKFLOW_NAME:-Build recipe book}"

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      printf 'RUNNER_HOME=%s\n' "$RUNNER_HOME"
      printf 'JAVA_VERSION=%s\n' "$JAVA_VERSION"
      printf 'NODE_VERSION=%s\n' "$NODE_VERSION"
      printf 'MC_VERSION=%s\n' "$MC_VERSION"
      printf 'MC_ASSET_INDEX=%s\n' "$MC_ASSET_INDEX"
      printf 'FORGE_BUILD=%s\n' "$FORGE_BUILD"
      printf 'HMC_REPO=%s\n' "${HMC_REPO:-3arthqu4ke/headlessmc}"
      printf 'HMC_VERSION=%s\n' "${HMC_VERSION:-}"
      printf 'MODPACK_DIR=%s\n' "$MODPACK_DIR"
      printf 'MODPACK_REPO=%s\n' "${MODPACK_REPO:-https://github.com/TerraFirmaGreg-Team/Modpack-Modern.git}"
      printf 'MODPACK_TAG=%s\n' "${MODPACK_TAG:-}"
      printf 'MWE_REPO=%s\n' "${MWE_REPO:-jmecn/minecraft-web-export}"
      printf 'MWE_VERSION=%s\n' "${MWE_VERSION:-}"
      printf 'RENDERER_REPO=%s\n' "${RENDERER_REPO:-jmecn/emi-recipe-renderer}"
      printf 'RENDERER_VERSION=%s\n' "${RENDERER_VERSION:-}"
      printf 'OPTIMIZE_REPO=%s\n' "${OPTIMIZE_REPO:-jmecn/emi-bundle-optimize}"
      printf 'OPTIMIZE_VERSION=%s\n' "${OPTIMIZE_VERSION:-}"
      printf 'SITE_VIEWER_REPO=%s\n' "${SITE_VIEWER_REPO:-jmecn/TFG-Recipe-Viewer-React}"
      printf 'SITE_VIEWER_VERSION=%s\n' "${SITE_VIEWER_VERSION:-}"
      printf 'EXPORT_WARMUP_TICKS=%s\n' "$EXPORT_WARMUP_TICKS"
      printf 'EXPORT_TIMEOUT_SECONDS=%s\n' "$EXPORT_TIMEOUT_SECONDS"
      printf 'EXPORT_RAW_DIR=%s\n' "${EXPORT_RAW_DIR:-export-raw}"
      printf 'EXPORT_BUNDLE_SUBDIR=%s\n' "${EXPORT_BUNDLE_SUBDIR:-emi}"
      printf 'EXPORT_OPT_DIR=%s\n' "${EXPORT_OPT_DIR:-export-opt}"
      printf 'EXPORT_RAW=%s\n' "$EXPORT_RAW"
      printf 'EXPORT_BUNDLE=%s\n' "$EXPORT_BUNDLE"
      printf 'EXPORT_OPT_STAGING=%s\n' "$EXPORT_OPT_STAGING"
      printf 'SITE_OUTPUT_DIR=%s\n' "$SITE_OUTPUT_DIR"
      printf 'EXPORT_ARTIFACT_NAME=%s\n' "${EXPORT_ARTIFACT_NAME:-recipe-book}"
      printf 'EXPORT_WORKFLOW_NAME=%s\n' "${EXPORT_WORKFLOW_NAME:-Build recipe book}"
    } >> "$GITHUB_ENV"
  fi
}

_normalize_version_ref() {
  echo "${1#v}"
}

# Resolve dependency refs for build.json (semver tags without leading v).
resolve_build_version_refs() {
  load_config

  if [[ -z "${MODPACK_TAG:-}" ]]; then
    unset MODPACK_TAG
  fi

  BUILD_REF_MODPACK="$(_normalize_version_ref "$(resolve_modpack_tag)")" || return 1
  BUILD_REF_MWE="$(_normalize_version_ref "$(resolve_mwe_tag)")" || return 1
  BUILD_REF_SITE="$(_normalize_version_ref "$(resolve_site_viewer_version)")" || return 1
  BUILD_REF_RENDERER="$(_normalize_version_ref "$(resolve_renderer_version)")" || return 1
  BUILD_REF_OPTIMIZE="$(_normalize_version_ref "$(resolve_optimize_version)")" || return 1
  BUILD_REF_HMC="$(_normalize_version_ref "$(resolve_hmc_version)")" || return 1
  BUILD_REF_REPO="$(git -C "$RBM_ROOT" rev-parse HEAD)"
}

_write_build_versions_json() {
  local out="${1:?output path required}"
  resolve_build_version_refs || return 1
  node -e "
const fs = require('fs');
const data = {
  modpack: process.argv[1],
  'minecraft-web-export': process.argv[2],
  'recipe-viewer-react': process.argv[3],
  'emi-recipe-renderer': process.argv[4],
  'emi-bundle-optimize': process.argv[5],
  headlessmc: process.argv[6],
  'recipebook-modern': process.argv[8],
};
fs.writeFileSync(process.argv[7], JSON.stringify(data, null, 2) + '\n');
" \
    "$BUILD_REF_MODPACK" \
    "$BUILD_REF_MWE" \
    "$BUILD_REF_SITE" \
    "$BUILD_REF_RENDERER" \
    "$BUILD_REF_OPTIMIZE" \
    "$BUILD_REF_HMC" \
    "$out" \
    "$BUILD_REF_REPO"
}

check_build_changes() {
  local build_json="${BUILD_JSON:-$RBM_ROOT/build.json}"
  resolve_build_version_refs || exit 1

  if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
    echo "Manual run — skip build.json gate"
    printf '%s\n' \
      "export_needed=true" \
      "deploy_needed=true" \
      "changed=true"
    return 0
  fi

  node -e "
const fs = require('fs');
const path = process.argv[1];
const current = {
  modpack: process.argv[2],
  'minecraft-web-export': process.argv[3],
  'recipe-viewer-react': process.argv[4],
  'emi-recipe-renderer': process.argv[5],
  'emi-bundle-optimize': process.argv[6],
  headlessmc: process.argv[7],
  'recipebook-modern': process.argv[8],
};
const exportKeys = ['modpack', 'minecraft-web-export'];
let recorded = {};
if (fs.existsSync(path)) {
  try { recorded = JSON.parse(fs.readFileSync(path, 'utf8')); } catch { recorded = {}; }
}
const keys = Object.keys(current);
const differs = (k) => String(recorded[k] ?? '') !== String(current[k] ?? '');
const exportNeeded = !fs.existsSync(path) || exportKeys.some(differs);
const deployNeeded = !fs.existsSync(path) || keys.some(differs);
const changed = deployNeeded;
const lines = [
  'export_needed=' + exportNeeded,
  'deploy_needed=' + deployNeeded,
  'changed=' + changed,
];
for (const k of keys) {
  if (differs(k)) lines.push('changed_' + k.replace(/[^a-z0-9]+/gi, '_') + '=true');
}
process.stdout.write(lines.join('\n') + '\n');
if (deployNeeded) {
  console.error('::group::build.json diff');
  for (const k of keys) {
    console.error(k + ': recorded=' + (recorded[k] ?? '<none>') + ' current=' + current[k]);
  }
  console.error('::endgroup::');
} else {
  console.log('build.json matches resolved versions — nothing to do');
}
" \
    "$build_json" \
    "$BUILD_REF_MODPACK" \
    "$BUILD_REF_MWE" \
    "$BUILD_REF_SITE" \
    "$BUILD_REF_RENDERER" \
    "$BUILD_REF_OPTIMIZE" \
    "$BUILD_REF_HMC" \
    "$BUILD_REF_REPO"
}

record_build_versions() {
  local build_json="${BUILD_JSON:-$RBM_ROOT/build.json}"
  _write_build_versions_json "$build_json"
  echo "Recorded build versions → ${build_json}"
  cat "$build_json"
}

commit_build_json() {
  local build_json="${BUILD_JSON:-$RBM_ROOT/build.json}"

  if [[ ! -f "$build_json" ]]; then
    echo "::error::Missing ${build_json}" >&2
    return 1
  fi

  cd "$RBM_ROOT"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add "$build_json"

  if git diff --staged --quiet; then
    echo "build.json unchanged — skip commit"
    return 0
  fi

  git commit -m "$(cat <<'EOF'
ci: update build.json

Record resolved dependency versions after a successful deploy.
EOF
)"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${GITHUB_REF_NAME:-main}"
  else
    git push
  fi
  echo "Committed and pushed build.json"
}

print_versions() {
  load_config

  if [[ -z "${MODPACK_TAG:-}" ]]; then
    unset MODPACK_TAG
  fi

  local modpack mwe site renderer optimize hmc bundle_id meta_file

  meta_file="$RBM_ROOT/export-meta/bundle-id"
  if [[ -f "$meta_file" ]]; then
    bundle_id="$(tr -d '[:space:]' < "$meta_file")"
    if [[ -z "$bundle_id" ]]; then
      echo "::error::export-meta/bundle-id is empty" >&2
      exit 1
    fi
    modpack="${bundle_id#tfg-}"
    echo "bundle from export-meta: ${bundle_id}"
  else
    modpack="$(resolve_modpack_tag)" || exit 1
    if [[ -z "$modpack" ]]; then
      echo "::error::Could not resolve Modpack-Modern release tag" >&2
      exit 1
    fi
    bundle_id="tfg-${modpack}"
  fi

  export MODPACK_TAG="$modpack"
  export BUNDLE_ID="$bundle_id"
  mwe="$(resolve_mwe_tag)" || exit 1
  site="$(resolve_site_viewer_version)" || exit 1
  renderer="$(resolve_renderer_version)" || exit 1
  optimize="$(resolve_optimize_version)" || exit 1
  hmc="$(resolve_hmc_version)" || exit 1

  export MWE_TAG="$mwe"
  export SITE_VIEWER_TAG="v${site}"
  export RENDERER_TAG="$renderer"
  export OPTIMIZE_TAG="$optimize"
  export HMC_TAG="$hmc"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'modpack_tag=%s\n' "$modpack"
      printf 'bundle_id=%s\n' "$bundle_id"
    } >> "$GITHUB_OUTPUT"
  fi

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      printf 'MODPACK_TAG=%s\n' "$modpack"
      printf 'BUNDLE_ID=%s\n' "$bundle_id"
      printf 'MWE_TAG=%s\n' "$mwe"
      printf 'MWE_VERSION=%s\n' "$mwe"
      printf 'SITE_VIEWER_VERSION=%s\n' "$site"
      printf 'RENDERER_VERSION=%s\n' "$renderer"
      printf 'OPTIMIZE_VERSION=%s\n' "$optimize"
      printf 'HMC_VERSION=%s\n' "$hmc"
    } >> "$GITHUB_ENV"
  fi

  echo "::group::CI resolved versions"
  printf '%s\n' \
    "modpack_tag=${modpack}" \
    "bundle_id=${bundle_id}" \
    "mwe_tag=${mwe}" \
    "site_viewer=v${site}" \
    "emi_recipe_renderer=${renderer}" \
    "emi_bundle_optimize=${optimize}" \
    "headlessmc=${hmc}" \
    "node=${NODE_VERSION}" \
    "minecraft=${MC_VERSION} (assets ${MC_ASSET_INDEX})" \
    "forge_build=${FORGE_BUILD}"
  echo "::endgroup::"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## Resolved versions"
      echo ""
      echo "| Component | Version |"
      echo "|-----------|---------|"
      echo "| Modpack-Modern | \`${modpack}\` |"
      echo "| Bundle id | \`${bundle_id}\` |"
      echo "| minecraft-web-export | \`${mwe}\` |"
      echo "| TFG-Recipe-Viewer-React | \`v${site}\` |"
      echo "| emi-recipe-renderer | \`${renderer}\` |"
      echo "| emi-bundle-optimize | \`${optimize}\` |"
      echo "| HeadlessMC | \`${hmc}\` |"
      echo "| Node (CI) | \`${NODE_VERSION}\` |"
      echo "| Minecraft / Forge | \`${MC_VERSION}\` / \`${FORGE_BUILD}\` |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

# --- Export ---

checkout_modpack() {
  local mp="${MODPACK_DIR:-$RBM_ROOT/Modpack-Modern}"
  local repo="${MODPACK_REPO:-https://github.com/TerraFirmaGreg-Team/Modpack-Modern.git}"
  local tag

  if [[ -n "${MODPACK_TAG:-}" ]]; then
    tag="$MODPACK_TAG"
    echo "Using MODPACK_TAG override: $tag"
  else
    tag="$(resolve_modpack_tag)"
    if [[ -z "$tag" ]]; then
      echo "::error::No semver release tags found on ${MODPACK_REPO:-Modpack-Modern}" >&2
      exit 1
    fi
    echo "Latest release tag: $tag"
  fi

  cd "$RBM_ROOT"
  if [[ -e "$mp/.git" ]]; then
    local current
    current="$(git -C "$mp" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$current" == "$tag" ]]; then
      echo "Modpack-Modern already at $tag"
    else
      echo "Replacing $mp (was ${current:-unknown}) with shallow clone @ $tag ..."
      rm -rf "$mp"
      git clone --depth 1 --branch "$tag" "$repo" "$mp"
    fi
  else
    echo "Shallow cloning Modpack-Modern @ $tag into $mp ..."
    git clone --depth 1 --branch "$tag" "$repo" "$mp"
  fi

  cd "$mp"
  git describe --tags --exact-match 2>/dev/null || git describe --tags --always

  export MODPACK_TAG="$tag"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "modpack_tag=$tag" >> "$GITHUB_OUTPUT"
  fi
}

prepare_bundle_id() {
  local tag="${MODPACK_TAG:?MODPACK_TAG required}"
  local id="tfg-${tag}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "bundle_id=${id}"
      echo "modpack_tag=${tag}"
    } >> "$GITHUB_OUTPUT"
  fi
  echo "bundle_id=${id} (modpack @ ${tag})"
}

prepare_export() {
  load_config
  checkout_modpack
  prepare_bundle_id
  print_versions
  echo "Modpack-Modern @ ${MODPACK_TAG} → bundle_id=tfg-${MODPACK_TAG}"
}

resolve_export_languages() {
  local lang_cfg="$RBM_ROOT/language.json"
  if [[ ! -f "$lang_cfg" ]]; then
    echo "en_us,zh_cn"
    return
  fi
  node -e "
const fs=require('fs');
const cfg=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
const arr=Array.isArray(cfg.enabledLocales)?cfg.enabledLocales:[];
const norm=[...new Set(arr.map(s=>String(s||'').trim().toLowerCase().replace(/-/g,'_')).filter(Boolean))];
process.stdout.write((norm.length?norm:['en_us','zh_cn']).join(','));
" "$lang_cfg"
}

export_languages() {
  local langs
  langs="$(resolve_export_languages)"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "export_languages<<EOF"
      echo "$langs"
      echo "EOF"
    } >> "$GITHUB_OUTPUT"
  fi
  echo "Export languages (language.json): ${langs}"
}

prep_node() {
  cd "$RBM_ROOT"
  local renderer_ver optimize_ver
  renderer_ver="$(resolve_renderer_version)" || exit 1
  optimize_ver="$(resolve_optimize_version)" || exit 1
  npm pkg set "dependencies.emi-recipe-renderer=${renderer_ver}"
  npm pkg set "dependencies.emi-bundle-optimize=${optimize_ver}"
  npm install --no-audit --no-fund
  echo "emi-recipe-renderer@${renderer_ver}"
  echo "emi-bundle-optimize@$(node -p "require('./node_modules/emi-bundle-optimize/package.json').version")"
}

install_gh_release_jar() {
  local repo=$1 tag=$2 jar_prefix=$3
  shift 3
  local extra_patterns=("$@")

  local ver="${tag#v}"
  local jar_name="${jar_prefix}-${ver}.jar"
  local mp="${MODPACK_DIR:-$RBM_ROOT/Modpack-Modern}"

  cd "$RBM_ROOT"
  rm -f "${jar_prefix}-"*.jar
  gh release download "$tag" --repo "$repo" --pattern "$jar_name" --clobber

  mkdir -p "$mp/mods"
  find "$mp/mods" -maxdepth 1 -name "${jar_prefix}*.jar" -delete
  for pat in "${extra_patterns[@]}"; do
    find "$mp/mods" -maxdepth 1 -name "$pat" -delete
  done

  local jar
  jar=$(ls "${jar_prefix}-"*.jar | head -1)
  if [[ -z "$jar" ]]; then
    echo "::error::No ${jar_prefix} jar from ${repo}@${tag}" >&2
    exit 1
  fi
  cp -v "$jar" "$mp/mods/"
}

install_mwe() {
  local mp="${MODPACK_DIR:-$RBM_ROOT/Modpack-Modern}"
  local mwe_tag
  mwe_tag="$(resolve_mwe_tag)" || exit 1
  echo "Installing minecraft-web-export ${mwe_tag}"

  install_gh_release_jar "${MWE_REPO:-jmecn/minecraft-web-export}" "$mwe_tag" minecraft-web-export \
    'field-guide*.jar'

  local cp_cfg="$mp/config/craftpresence.json"
  if [[ -f "$cp_cfg" ]]; then
    python3 - "$cp_cfg" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg.setdefault("displaySettings", {}).setdefault("presenceData", {})["enabled"] = False
cfg.setdefault("advancedSettings", {})["maxConnectionAttempts"] = 1
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PY
  fi
}

install_display_deps() {
  if command -v xvfb-run >/dev/null 2>&1; then
    return 0
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    xvfb x11-xserver-utils \
    libgl1 libgl1-mesa-dri \
    libopenal1
}

prepare_game() {
  install_display_deps
  install_mwe
  setup_hmc
}

setup_hmc() {
  local hmc_ver mc_ver forge mp mp_abs launcher

  hmc_ver="$(resolve_hmc_version)" || exit 1
  mc_ver="${MC_VERSION:?MC_VERSION required}"
  forge="${FORGE_BUILD:?FORGE_BUILD required}"
  mp="${MODPACK_DIR:-Modpack-Modern}"
  mp_abs="$(cd "$RBM_ROOT/$mp" && pwd)"
  launcher="headlessmc-launcher-${hmc_ver}.jar"

  cd "$RBM_ROOT"
  if [[ ! -f "$launcher" ]]; then
    gh release download "$hmc_ver" \
      --repo "${HMC_REPO:-3arthqu4ke/headlessmc}" \
      --pattern "$launcher" \
      --clobber
  fi

  mkdir -p HeadlessMC
  cat > HeadlessMC/config.properties <<EOF
hmc.java.versions=$JAVA_HOME/bin/java
hmc.gamedir=$mp_abs
hmc.offline=true
hmc.rethrow.launch.exceptions=true
hmc.exit.on.failed.command=true
EOF

  if [[ ! -f "$HOME/.minecraft/versions/$mc_ver/$mc_ver.json" ]]; then
    java -jar "$launcher" --command "download $mc_ver"
  fi
  if ! ls "$HOME/.minecraft/versions" 2>/dev/null | grep -q "$forge"; then
    java -jar "$launcher" --command "forge $mc_ver --uid $forge"
  fi
}

verify_emi_bundle() {
  local bundle="${EXPORT_BUNDLE:?EXPORT_BUNDLE required}"
  local bundle_json="$bundle/bundle.json"

  if [[ ! -f "$bundle_json" ]]; then
    echo "::error::Missing $bundle_json" >&2
    return 1
  fi

  local schema
  schema="$(node -e "const b=require(process.argv[1]); console.log(b.schema??'')" "$bundle_json")"
  if [[ "$schema" != "2" ]]; then
    echo "::error::bundle.json schema must be 2 (got: ${schema:-<missing>})." >&2
    return 1
  fi

  cd "$RBM_ROOT"
  npx emi-bundle-optimize validate "$bundle"
}

launch_export() {
  local mp hmc_ver launcher langs

  mp="${MODPACK_DIR:-$RBM_ROOT/Modpack-Modern}"
  hmc_ver="$(resolve_hmc_version)" || exit 1
  launcher="headlessmc-launcher-${hmc_ver}.jar"

  mkdir -p "$mp/config" "$mp/saves" "${EXPORT_RAW:?EXPORT_RAW required}"
  cp -f "$CI_DIR/config/export-fml.toml" "$mp/config/fml.toml"
  cp -f "$CI_DIR/config/export-forge-client.toml" "$mp/config/forge-client.toml"
  cat > "$mp/options.txt" <<EOF
onboardAccessibility:false
pauseOnLostFocus:false
EOF

  if [[ "${MWE_JVM_FLAGS:-}" != *minecraftWebExport.exportLanguages=* ]]; then
    langs="$(resolve_export_languages)"
    MWE_JVM_FLAGS="${MWE_JVM_FLAGS} -DminecraftWebExport.exportLanguages=${langs}"
    export MWE_JVM_FLAGS
    echo "Export languages (from language.json): ${langs}"
  fi

  cd "$RBM_ROOT"
  xvfb-run --server-args="-screen 0 1280x720x24" -a java \
    -Dhmc.check.xvfb=true \
    -jar "$launcher" \
    --command "launch .*forge.* -regex --jvm \"${MWE_JVM_FLAGS:?MWE_JVM_FLAGS required}\""

  verify_emi_bundle
}

write_export_meta() {
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local modpack_tag="${MODPACK_TAG:?MODPACK_TAG required}"
  local out="$RBM_ROOT/export-meta"

  mkdir -p "$out"
  printf '%s\n' "$bundle_id" > "$out/bundle-id"
  printf '%s\n' "$modpack_tag" > "$out/modpack-tag"
  echo "Wrote export-meta (bundle_id=$bundle_id modpack_tag=$modpack_tag)"
}

finalize_export() {
  write_export_meta
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local archive="$RBM_ROOT/emi-raw-${bundle_id}.tar.gz"
  local subdir="${EXPORT_BUNDLE_SUBDIR:-emi}"

  load_config
  node -e "const b=require(process.argv[1]); console.log('bundle.json schema', b.schema, 'imageScale', b.imageScale)" "${EXPORT_BUNDLE}/bundle.json"
  tar -czf "$archive" -C "${EXPORT_RAW}" "$subdir"
  ls -lh "$archive"
}

collect_export_debug() {
  local mp="${MODPACK_DIR:-$RBM_ROOT/Modpack-Modern}"
  local out="$RBM_ROOT/ci-debug"
  local phase="${1:-}"

  rm -rf "$out"
  mkdir -p "$out"

  if [[ -d "$mp/logs" ]]; then
    mkdir -p "$out/modpack/logs"
    for f in "$mp/logs"/*; do
      [[ -f "$f" ]] || continue
      local base
      base=$(basename "$f")
      if [[ "$base" == latest.log ]] || [[ $(stat -c%s "$f" 2>/dev/null || stat -f%z "$f") -lt 5242880 ]]; then
        cp -a "$f" "$out/modpack/logs/"
      fi
    done
  fi

  if [[ -d "$mp/crash-reports" ]]; then
    cp -a "$mp/crash-reports" "$out/modpack/"
  fi

  local bundle="$RBM_ROOT/export-raw/emi"
  if [[ -f "$bundle/bundle.json" ]]; then
    mkdir -p "$out/export-raw/emi"
    cp "$bundle/bundle.json" "$out/export-raw/emi/"
    du -sh "$bundle" > "$out/export-raw/emi-size.txt" 2>/dev/null || true
    find "$bundle" -type f 2>/dev/null | head -200 > "$out/export-raw/emi-file-sample.txt" || true
  fi

  if [[ "$phase" == "optimize" ]]; then
    local opt="$RBM_ROOT/export-opt"
    if [[ -f "$opt/optimize-report.json" ]]; then
      mkdir -p "$out/export-opt"
      cp "$opt/optimize-report.json" "$out/export-opt/"
    fi
    if [[ -d "$opt" ]]; then
      du -sh "$opt" > "$out/export-opt-size.txt" 2>/dev/null || true
    fi
  fi

  if [[ -z "$(find "$out" -type f 2>/dev/null | head -1)" ]]; then
    echo "no debug files collected" > "$out/README.txt"
  fi

  echo "debug files under $out:"
  find "$out" -type f | head -50
}

# --- Deploy ---

prepare_deploy() {
  load_config
  resolve_bundle_id
}

resolve_bundle_id() {
  local id tag

  if [[ -n "${BUNDLE_ID_INPUT:-}" ]]; then
    id="$BUNDLE_ID_INPUT"
  elif [[ -f "$RBM_ROOT/export-meta/bundle-id" ]]; then
    id="$(tr -d '\r\n' < "$RBM_ROOT/export-meta/bundle-id")"
  elif [[ -n "${MODPACK_TAG:-}" ]]; then
    id="tfg-${MODPACK_TAG}"
  else
    load_config
    if [[ -z "${MODPACK_TAG:-}" ]]; then
      unset MODPACK_TAG
    fi
    tag="$(resolve_modpack_tag)"
    if [[ -z "$tag" ]]; then
      echo "::error::Could not resolve modpack tag for bundle id" >&2
      exit 1
    fi
    id="tfg-${tag}"
    export MODPACK_TAG="$tag"
  fi

  export BUNDLE_ID="$id"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "bundle_id=${id}" >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'BUNDLE_ID=%s\n' "$id" >> "$GITHUB_ENV"
  fi
  echo "bundle_id=${id}"
}

install_bundle() {
  case "${ACQUIRE:-extract}" in
    extract) extract_bundle ;;
    fetch) fetch_bundle ;;
    *)
      echo "::error::ACQUIRE must be extract or fetch (got: ${ACQUIRE:-})" >&2
      exit 1
      ;;
  esac
}

extract_bundle() {
  local export_raw="${EXPORT_RAW:?EXPORT_RAW required}"
  local subdir="${EXPORT_BUNDLE_SUBDIR:-emi}"
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local dest="${export_raw}/${subdir}"
  local archive="$RBM_ROOT/emi-raw-${bundle_id}.tar.gz"

  load_config

  if [[ ! -f "$archive" ]]; then
    echo "::error::Missing ${archive} after artifact download" >&2
    ls -la "$RBM_ROOT" >&2
    exit 1
  fi

  rm -rf "$RBM_ROOT/emi"
  tar -xzf "$archive" -C "$RBM_ROOT"

  if [[ ! -f "$RBM_ROOT/emi/bundle.json" ]]; then
    echo "::error::${archive} did not contain emi/bundle.json" >&2
    exit 1
  fi

  mkdir -p "$export_raw"
  rm -rf "$dest"
  cp -a "$RBM_ROOT/emi" "$dest"
  rm -rf "$RBM_ROOT/emi" "$archive"

  local schema image_scale
  schema="$(node -e "const b=require(process.argv[1]); console.log(b.schema??'')" "${dest}/bundle.json")"
  image_scale="$(node -e "const b=require(process.argv[1]); console.log(b.imageScale??'')" "${dest}/bundle.json")"
  echo "Raw bundle at ${dest}/bundle.json (schema=${schema} imageScale=${image_scale})"
}

fetch_bundle() {
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"

  load_config

  if [[ -f "${EXPORT_BUNDLE}/bundle.json" ]]; then
    echo "Raw bundle already at ${EXPORT_BUNDLE}"
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI required to download artifact ${EXPORT_ARTIFACT_NAME}" >&2
    exit 1
  fi

  local artifact_name="${EXPORT_ARTIFACT_NAME:-recipe-book}"
  local workflow_name="${EXPORT_WORKFLOW_NAME:-Build recipe book}"

  local run_id
  run_id="$(
    gh run list \
      --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" \
      --workflow "$workflow_name" \
      --branch "${GITHUB_REF_NAME:-main}" \
      --status success \
      --limit 1 \
      --json databaseId \
      -q '.[0].databaseId'
  )"

  if [[ -z "$run_id" ]]; then
    echo "::error::No successful「${workflow_name}」run on branch ${GITHUB_REF_NAME:-main}" >&2
    exit 1
  fi

  rm -f "$RBM_ROOT/emi-raw-${bundle_id}.tar.gz"
  gh run download "$run_id" --repo "$GITHUB_REPOSITORY" -n "$artifact_name" -D "$RBM_ROOT"
  extract_bundle
  echo "Installed export from run ${run_id} (artifact ${artifact_name})"
}

fetch_viewer_site() {
  local repo="${SITE_VIEWER_REPO:-jmecn/TFG-Recipe-Viewer-React}"
  local site_dir="${RBM_ROOT}/${SITE_OUTPUT_DIR:-site}"
  local version tag

  version="$(resolve_site_viewer_version)" || return 1
  echo "TFG-Recipe-Viewer-React site @ v${version}"
  tag="v${version}"

  if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI required to download viewer site from ${repo} ${tag}" >&2
    return 1
  fi

  local staging archive
  staging="$(mktemp -d)"
  archive="tfg-recipe-viewer-site-v${version}.tar.gz"

  echo "::group::Fetch viewer site ${tag} (${repo})"
  if ! ( cd "$staging" && gh release download "$tag" --repo "$repo" --pattern "$archive" --clobber ); then
    rm -rf "$staging"
    echo "::error::gh release download failed for ${repo} ${tag} pattern ${archive}" >&2
    return 1
  fi

  if [[ ! -f "$staging/$archive" ]]; then
    rm -rf "$staging"
    echo "::error::Release asset ${archive} not found on ${repo} tag ${tag}" >&2
    return 1
  fi

  mkdir -p "$site_dir/bundles"
  find "$site_dir" -mindepth 1 -maxdepth 1 ! -name bundles -exec rm -rf {} +
  tar -xzf "$staging/$archive" -C "$site_dir"

  if [[ ! -f "$site_dir/index.html" ]]; then
    rm -rf "$staging"
    echo "::error::Extracted site missing index.html (layout=dist-root expected)" >&2
    return 1
  fi

  if [[ ! -f "$site_dir/bundles.json" ]]; then
    rm -rf "$staging"
    echo "::error::Extracted site missing bundles.json" >&2
    return 1
  fi

  echo "Viewer site installed at ${site_dir} (${archive})"
  echo "::endgroup::"
  rm -rf "$staging"
}

optimize_and_stage() {
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local raw="${EXPORT_BUNDLE:?EXPORT_BUNDLE required}"
  local out="${EXPORT_OPT_STAGING:?EXPORT_OPT_STAGING required}"
  local site_dir="${RBM_ROOT}/${SITE_OUTPUT_DIR:-site}"

  if [[ ! -f "$raw/bundle.json" ]]; then
    echo "::error::Raw bundle missing at $raw — run Export EMI bundle first." >&2
    exit 1
  fi

  cd "$RBM_ROOT"
  verify_emi_bundle
  echo "::group::emi-bundle-optimize"
  npx emi-bundle-optimize optimize \
    --in "$raw" \
    --out "$out" \
    --force \
    --no-recipe-webp
  echo "::endgroup::"
  npm run copy -- --id "$bundle_id" "$out"
  npm run validate -- "${site_dir}/bundles/$bundle_id"
  echo "Optimized bundle staged at ${site_dir}/bundles/$bundle_id"
}

assemble_deploy_site() {
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local site_dir="${RBM_ROOT}/${SITE_OUTPUT_DIR:-site}"
  local bundle_root="${site_dir}/bundles/$bundle_id"

  if [[ ! -f "$site_dir/index.html" ]]; then
    echo "::error::Missing $site_dir/index.html — run fetch-viewer-site first." >&2
    exit 1
  fi

  if [[ ! -f "$bundle_root/bundle.json" ]]; then
    echo "::error::Missing bundle at $bundle_root — run optimize first." >&2
    exit 1
  fi

  cd "$RBM_ROOT"
  cp "$RBM_ROOT/language.json" "$site_dir/language.json"
  echo "Synced language.json → $site_dir/language.json"
  npm run copy -- --id "$bundle_id" "$bundle_root"
  npm run validate
  if ! compgen -G "$site_dir/assets/*.js" > /dev/null; then
    echo "::error::Missing $site_dir/assets/*.js — viewer site release may be corrupt." >&2
    exit 1
  fi
  echo "Deploy site ready at ${site_dir} (bundle: $bundle_id, viewer: v$(resolve_site_viewer_version))"
}

build_site() {
  load_config
  prep_node
  fetch_viewer_site
  optimize_and_stage
  assemble_deploy_site
}

resolve_release_tag() {
  local strip_v=0
  local args=()
  for arg in "$@"; do
    case "$arg" in
      --version|-V) strip_v=1 ;;
      *) args+=("$arg") ;;
    esac
  done

  local repo="${args[0]:?repo required (owner/name or https://github.com/...git)}"
  local pinned="${args[1]:-}"

  if [[ "$strip_v" -eq 1 ]]; then
    resolve_github_release_version "$repo" "$pinned"
  else
    resolve_github_release_ref "$repo" "$pinned"
  fi
}

usage() {
  cat <<'EOF'
Usage: bash ci/run.sh <command>

Workflow composites:
  prepare-export      env + modpack checkout + bundle id + resolve versions
  prepare-game        xvfb deps + MWE jar + HeadlessMC
  finalize-export     export-meta + tar (needs BUNDLE_ID, MODPACK_TAG)
  prepare-deploy      env + resolve bundle id
  install-bundle      extract or fetch (ACQUIRE=extract|fetch, BUNDLE_ID)
  build-site            fetch React site + optimize bundle + assemble deploy site

Granular (local debugging):
  env, print-versions, checkout-modpack, prepare-bundle-id, export-languages,
  prep-node, install-mods, setup-hmc, launch-export, write-export-meta,
  resolve-bundle-id, extract-bundle, fetch-bundle, verify-emi-bundle,
  fetch-viewer-site, optimize-and-stage, assemble-deploy-site,
  collect-export-debug, resolve-release-tag,
  check-build-changes, record-build-versions, commit-build-json
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    usage >&2
    exit 1
  fi
  shift

  case "$cmd" in
    env) load_config "$@" ;;
    print-versions) print_versions "$@" ;;
    prepare-export) prepare_export "$@" ;;
    prepare-game) prepare_game "$@" ;;
    finalize-export) finalize_export "$@" ;;
    prepare-deploy) prepare_deploy "$@" ;;
    install-bundle) install_bundle "$@" ;;
    checkout-modpack) checkout_modpack "$@" ;;
    prepare-bundle-id) prepare_bundle_id "$@" ;;
    export-languages) export_languages "$@" ;;
    prep-node) prep_node "$@" ;;
    install-mods) install_mwe "$@" ;;
    setup-hmc) setup_hmc "$@" ;;
    launch-export) launch_export "$@" ;;
    write-export-meta) write_export_meta "$@" ;;
    resolve-bundle-id) resolve_bundle_id "$@" ;;
    extract-bundle) extract_bundle "$@" ;;
    fetch-bundle) fetch_bundle "$@" ;;
    verify-emi-bundle) verify_emi_bundle "$@" ;;
    fetch-viewer-site) fetch_viewer_site "$@" ;;
    optimize-and-stage) optimize_and_stage "$@" ;;
    assemble-deploy-site) assemble_deploy_site "$@" ;;
    build-site) build_site "$@" ;;
    collect-export-debug) collect_export_debug "${1:-}" ;;
    resolve-release-tag) resolve_release_tag "$@" ;;
    check-build-changes) check_build_changes "$@" ;;
    record-build-versions) record_build_versions "$@" ;;
    commit-build-json) commit_build_json "$@" ;;
    -h|--help|help) usage ;;
    *)
      echo "::error::Unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
fi
