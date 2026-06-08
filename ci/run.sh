#!/usr/bin/env bash
# RecipeBook-Modern CI — config, release resolution, export, deploy, site build.
# Usage: bash ci/run.sh <command>
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_SCRIPTS="${CI_DIR}/scripts"
RBM_ROOT="$(cd "$CI_DIR/.." && pwd)"

ci_node() {
  node "$CI_SCRIPTS/$1" "${@:2}"
}

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
  export EXPORT_CACHE_KEY_PREFIX="${EXPORT_CACHE_KEY_PREFIX:-emi-export}"

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
      printf 'EXPORT_CACHE_KEY_PREFIX=%s\n' "${EXPORT_CACHE_KEY_PREFIX:-emi-export}"
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
}

resolve_build_json_url() {
  if [[ -n "${BUILD_JSON_URL:-}" ]]; then
    echo "$BUILD_JSON_URL"
    return 0
  fi
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    echo "https://${GITHUB_REPOSITORY%/*}.github.io/${GITHUB_REPOSITORY#*/}/build.json"
    return 0
  fi
  return 1
}

# Last published versions: live site URL, then local site/build.json, else empty.
fetch_recorded_build_json() {
  local dest="${1:?dest path required}"
  local url local_site

  if url="$(resolve_build_json_url 2>/dev/null)"; then
    if curl -fsSL --retry 2 --retry-delay 1 "$url" -o "$dest" 2>/dev/null; then
      echo "Loaded published build.json from ${url}" >&2
      return 0
    fi
    echo "No published build.json at ${url} — first deploy or site not ready" >&2
  fi

  local_site="${RBM_ROOT}/${SITE_OUTPUT_DIR:-site}/build.json"
  if [[ -f "$local_site" ]]; then
    cp "$local_site" "$dest"
    echo "Using local ${local_site}" >&2
    return 0
  fi

  echo '{}' > "$dest"
}

_write_build_versions_json() {
  local out="${1:?output path required}"
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local hash_len="${SITE_RELEASE_HASH_LENGTH:-7}"
  resolve_build_version_refs || return 1
  ci_node write-build-versions.mjs \
    "$BUILD_REF_MODPACK" \
    "$BUILD_REF_MWE" \
    "$BUILD_REF_SITE" \
    "$BUILD_REF_RENDERER" \
    "$BUILD_REF_OPTIMIZE" \
    "$BUILD_REF_HMC" \
    "$bundle_id" \
    "$hash_len" \
    "$out"
}

check_build_changes() {
  local build_json
  build_json="$(mktemp)"
  resolve_build_version_refs || exit 1
  fetch_recorded_build_json "$build_json"

  ci_node check-build-changes.mjs \
    "$build_json" \
    "$BUILD_REF_MODPACK" \
    "$BUILD_REF_MWE" \
    "$BUILD_REF_SITE" \
    "$BUILD_REF_RENDERER" \
    "$BUILD_REF_OPTIMIZE" \
    "$BUILD_REF_HMC"
  rm -f "$build_json"
}

record_build_versions() {
  local site_dir="${RBM_ROOT}/${SITE_OUTPUT_DIR:-site}"
  local build_json="${BUILD_JSON:-$site_dir/build.json}"
  mkdir -p "$site_dir"
  _write_build_versions_json "$build_json"
  echo "Recorded build versions → ${build_json} (deployed with site)"
  cat "$build_json"
}

publish_site_release() {
  load_config

  local site_dir="${RBM_ROOT}/${SITE_OUTPUT_DIR:-site}"
  local build_json="$site_dir/build.json"
  local asset_name="${SITE_RELEASE_ASSET_NAME:-recipe-book-site.tar}"
  local archive="$RBM_ROOT/$asset_name"
  local release_tag notes

  if [[ ! -f "$build_json" ]]; then
    echo "::error::Missing ${build_json} — run record-build-versions first" >&2
    exit 1
  fi

  if [[ ! -f "$site_dir/index.html" ]]; then
    echo "::error::Missing ${site_dir}/index.html — run build-site first" >&2
    exit 1
  fi

  release_tag="$(ci_node read-release-tag.mjs "$build_json")"

  if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI required to publish site release" >&2
    exit 1
  fi

  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN is required to publish site release" >&2
    exit 1
  fi

  echo "::group::Package site release (${release_tag})"
  rm -f "$archive"
  tar -cf "$archive" -C "$site_dir" .
  echo "Created ${archive} ($(du -h "$archive" | awk '{print $1}'))"
  echo "::endgroup::"

  if gh release view "$release_tag" --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" >/dev/null 2>&1; then
    echo "Release ${release_tag} already exists — skipping upload"
    rm -f "$archive"
    return 0
  fi

  notes="$(mktemp)"
  cp "$build_json" "$notes"

  echo "::group::Create GitHub Release ${release_tag}"
  gh release create "$release_tag" "$archive" \
    --repo "${GITHUB_REPOSITORY}" \
    --title "Recipe book site ${release_tag}" \
    --notes-file "$notes"
  rm -f "$notes" "$archive"
  echo "Published ${asset_name} → release ${release_tag}"
  echo "::endgroup::"
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

export_cache_fingerprint() {
  resolve_build_version_refs || return 1
  # Export gate: modpack + minecraft-web-export
  printf '%s:%s' "$BUILD_REF_MODPACK" "$BUILD_REF_MWE" \
    | sha256sum | awk '{print substr($1,1,8)}'
}

export_cache_key() {
  local bundle_id="${1:?bundle_id required}"
  local fingerprint="${2:?fingerprint required}"
  printf '%s-%s-%s' "${EXPORT_CACHE_KEY_PREFIX:-emi-export}" "$bundle_id" "$fingerprint"
}

bundle_id_for_tag() {
  printf 'tfg-%s' "${1:?modpack tag required}"
}

_write_bundle_outputs() {
  local tag="${1:?modpack tag required}"
  local label="${2:-bundle}"
  local id cache_key fingerprint

  export MODPACK_TAG="$tag"
  id="$(bundle_id_for_tag "$tag")"
  export BUNDLE_ID="$id"
  fingerprint="$(export_cache_fingerprint)" || exit 1
  cache_key="$(export_cache_key "$id" "$fingerprint")"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "bundle_id=${id}"
      echo "modpack_tag=${tag}"
      echo "export_cache_key=${cache_key}"
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'BUNDLE_ID=%s\n' "$id" >> "$GITHUB_ENV"
  fi
  echo "${label} bundle_id=${id} export_cache_key=${cache_key}"
}

prepare_bundle_id() {
  _write_bundle_outputs "${MODPACK_TAG:?MODPACK_TAG required}" "export"
}

prepare_check_bundle() {
  load_config
  local tag="${MODPACK_TAG:-}"

  if [[ -z "$tag" ]]; then
    tag="$(resolve_modpack_tag)" || exit 1
  fi
  _write_bundle_outputs "$tag" "check"
}

finalize_export_decision() {
  local export_needed=false

  if [[ "${VERSION_EXPORT_NEEDED:-false}" == "true" ]]; then
    export_needed=true
    echo "Export required: version gate" >&2
  elif [[ "${EXPORT_CACHE_HIT:-}" != "true" ]]; then
    export_needed=true
    echo "Export required: cache miss (${EXPORT_CACHE_KEY:-<unset>})" >&2
  else
    echo "Export skipped: versions unchanged and export cache hit" >&2
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "export_needed=${export_needed}" >> "$GITHUB_OUTPUT"
  else
    echo "export_needed=${export_needed}"
  fi
}

prepare_export() {
  load_config
  checkout_modpack
  prepare_bundle_id
  print_versions
}

resolve_export_languages() {
  ci_node resolve-export-languages.mjs "$RBM_ROOT/language.json"
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
  schema="$(ci_node read-bundle-field.mjs "$bundle_json" schema)"
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
  echo "bundle.json schema $(ci_node read-bundle-field.mjs "${EXPORT_BUNDLE}/bundle.json" schema) imageScale $(ci_node read-bundle-field.mjs "${EXPORT_BUNDLE}/bundle.json" imageScale)"
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
    id="$(bundle_id_for_tag "$MODPACK_TAG")"
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
    id="$(bundle_id_for_tag "$tag")"
    export MODPACK_TAG="$tag"
  fi

  export BUNDLE_ID="$id"

  local fingerprint cache_key
  fingerprint="$(export_cache_fingerprint)" || exit 1
  cache_key="$(export_cache_key "$id" "$fingerprint")"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "bundle_id=${id}"
      echo "export_cache_key=${cache_key}"
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'BUNDLE_ID=%s\n' "$id" >> "$GITHUB_ENV"
  fi
  echo "deploy bundle_id=${id} export_cache_key=${cache_key}"
}

extract_bundle() {
  local export_raw="${EXPORT_RAW:?EXPORT_RAW required}"
  local subdir="${EXPORT_BUNDLE_SUBDIR:-emi}"
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local dest="${export_raw}/${subdir}"
  local archive="$RBM_ROOT/emi-raw-${bundle_id}.tar.gz"

  load_config

  if [[ ! -f "$archive" ]]; then
    echo "::error::Missing ${archive} after export cache restore" >&2
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
  schema="$(ci_node read-bundle-field.mjs "${dest}/bundle.json" schema)"
  image_scale="$(ci_node read-bundle-field.mjs "${dest}/bundle.json" imageScale)"
  echo "Raw bundle at ${dest}/bundle.json (schema=${schema} imageScale=${image_scale})"
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
  extract-bundle      unpack export cache (BUNDLE_ID)
  build-site          fetch React site + optimize bundle + assemble deploy site

Granular (local debugging):
  env, print-versions, checkout-modpack, prepare-bundle-id, export-languages,
  prep-node, install-mods, setup-hmc, launch-export, write-export-meta,
  resolve-bundle-id, extract-bundle, verify-emi-bundle,
  prepare-check-bundle, finalize-export-decision,
  fetch-viewer-site, optimize-and-stage, assemble-deploy-site,
  collect-export-debug, resolve-release-tag,
  check-build-changes, record-build-versions, publish-site-release
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
    extract-bundle) extract_bundle "$@" ;;
    checkout-modpack) checkout_modpack "$@" ;;
    prepare-bundle-id) prepare_bundle_id "$@" ;;
    prepare-check-bundle) prepare_check_bundle "$@" ;;
    finalize-export-decision) finalize_export_decision "$@" ;;
    export-languages) export_languages "$@" ;;
    prep-node) prep_node "$@" ;;
    install-mods) install_mwe "$@" ;;
    setup-hmc) setup_hmc "$@" ;;
    launch-export) launch_export "$@" ;;
    write-export-meta) write_export_meta "$@" ;;
    resolve-bundle-id) resolve_bundle_id "$@" ;;
    extract-bundle) extract_bundle "$@" ;;
    verify-emi-bundle) verify_emi_bundle "$@" ;;
    fetch-viewer-site) fetch_viewer_site "$@" ;;
    optimize-and-stage) optimize_and_stage "$@" ;;
    assemble-deploy-site) assemble_deploy_site "$@" ;;
    build-site) build_site "$@" ;;
    collect-export-debug) collect_export_debug "${1:-}" ;;
    resolve-release-tag) resolve_release_tag "$@" ;;
    check-build-changes) check_build_changes "$@" ;;
    record-build-versions) record_build_versions "$@" ;;
    publish-site-release) publish_site_release "$@" ;;
    -h|--help|help) usage ;;
    *)
      echo "::error::Unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
fi
