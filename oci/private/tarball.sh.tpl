#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly STAGING_DIR=$(mktemp -d)
readonly YQ="{{yq}}"
readonly IMAGE_DIR="{{image_dir}}"
readonly BLOBS_DIR="${STAGING_DIR}/blobs"
readonly TARBALL_PATH="$(pwd)/{{tarball_path}}"
readonly TAGS_FILE="{{tags}}"
readonly INDEX_FILE="${IMAGE_DIR}/index.json"

cp_f_with_mkdir() {
  SRC="$1"
  DST="$2"
  mkdir -p "$(dirname "${DST}")"
  cp -f "${SRC}" "${DST}"
}

REPOTAGS=($(cat "${TAGS_FILE}"))

MANIFESTS_LENGTH=$("${YQ}" eval '.manifests | length' "${INDEX_FILE}")
if [[ "${MANIFESTS_LENGTH}" != 1 ]]; then
  echo >&2 "Expected exactly one manifest in ${INDEX_FILE}"
  exit 1
fi

MEDIA_TYPE=$("${YQ}" eval ".manifests[0].mediaType" "${INDEX_FILE}")
if [[ "${MEDIA_TYPE}" == "application/vnd.oci.image.index.v1+json" ]]; then
  # Handle multi-architecture image indexes.
  # Ideally the toolchains we rely on would output these for us, but they don't seem to.

  echo -n '{"imageLayoutVersion": "1.0.0"}' > "${STAGING_DIR}/oci-layout"

  INDEX_FILE_MANIFEST_DIGEST=$("${YQ}" eval '.manifests[0].digest | sub(":"; "/")' "${INDEX_FILE}" | tr  -d '"')
  INDEX_FILE_MANIFEST_BLOB_PATH="${IMAGE_DIR}/blobs/${INDEX_FILE_MANIFEST_DIGEST}"

  cp_f_with_mkdir "${INDEX_FILE_MANIFEST_BLOB_PATH}" "${BLOBS_DIR}/${INDEX_FILE_MANIFEST_DIGEST}"

  IMAGE_MANIFESTS_DIGESTS=($("${YQ}" '.manifests[] | .digest | sub(":"; "/")' "${INDEX_FILE_MANIFEST_BLOB_PATH}"))

  for IMAGE_MANIFEST_DIGEST in "${IMAGE_MANIFESTS_DIGESTS[@]}"; do
    IMAGE_MANIFEST_BLOB_PATH="${IMAGE_DIR}/blobs/${IMAGE_MANIFEST_DIGEST}"
    cp_f_with_mkdir "${IMAGE_MANIFEST_BLOB_PATH}" "${BLOBS_DIR}/${IMAGE_MANIFEST_DIGEST}"

    CONFIG_DIGEST=$("${YQ}" eval '.config.digest  | sub(":"; "/")' ${IMAGE_MANIFEST_BLOB_PATH})
    CONFIG_BLOB_PATH="${IMAGE_DIR}/blobs/${CONFIG_DIGEST}"
    cp_f_with_mkdir "${CONFIG_BLOB_PATH}" "${BLOBS_DIR}/${CONFIG_DIGEST}"

    LAYER_DIGESTS=$("${YQ}" eval '.layers | map(.digest | sub(":"; "/"))' "${IMAGE_MANIFEST_BLOB_PATH}")
    for LAYER_DIGEST in $("${YQ}" ".[]" <<< $LAYER_DIGESTS); do
      cp_f_with_mkdir "${IMAGE_DIR}/blobs/${LAYER_DIGEST}" ${BLOBS_DIR}/${LAYER_DIGEST}
    done
  done

  TAG_COUNT=${#REPOTAGS[@]}
  INDEX_MANIFEST_COUNT="$("${YQ}" eval ".manifests | length" "${IMAGE_DIR}/index.json")"

  REPEATED_TAGS=()
  for TAG in "${REPOTAGS[@]}"; do
    if [[ "${INDEX_MANIFEST_COUNT}" -gt 0 ]]; then
      for i in $(seq 1 "${INDEX_MANIFEST_COUNT}"); do
        REPEATED_TAGS+=("${TAG}")
      done
    fi
  done

  MANIFEST_COPIES=".manifests"
  if [[ "${#REPOTAGS[@]}" -gt 1 ]]; then
    for i in $(seq 2 "${#REPOTAGS[@]}"); do
      MANIFEST_COPIES="${MANIFEST_COPIES} + .manifests"
    done
  fi

  repeated_tags="${REPEATED_TAGS[@]}" "${YQ}" -o json eval "(.manifests = ${MANIFEST_COPIES}) *d {\"manifests\": (env(repeated_tags) | split \" \" | map {\"annotations\": {\"org.opencontainers.image.ref.name\": .}})}" "${IMAGE_DIR}/index.json" > "${STAGING_DIR}/index.json"
else
  # Assume we're dealing with a single application/vnd.docker.distribution.manifest.list.v2+json manifest.

  MANIFEST_DIGEST=$(${YQ} eval '.manifests[0].digest | sub(":"; "/")' "${INDEX_FILE}" | tr  -d '"')
  MANIFEST_BLOB_PATH="${IMAGE_DIR}/blobs/${MANIFEST_DIGEST}"

  CONFIG_DIGEST=$(${YQ} eval '.config.digest  | sub(":"; "/")' ${MANIFEST_BLOB_PATH})
  CONFIG_BLOB_PATH="${IMAGE_DIR}/blobs/${CONFIG_DIGEST}"

  LAYERS=$(${YQ} eval '.layers | map(.digest | sub(":"; "/"))' ${MANIFEST_BLOB_PATH})

  cp_f_with_mkdir "${CONFIG_BLOB_PATH}" "${BLOBS_DIR}/${CONFIG_DIGEST}"

  for LAYER in $(${YQ} ".[]" <<< $LAYERS); do
    cp_f_with_mkdir "${IMAGE_DIR}/blobs/${LAYER}" "${BLOBS_DIR}/${LAYER}.tar.gz"
  done

  repo_tags="${REPOTAGS[@]}" \
  config="blobs/${CONFIG_DIGEST}" \
  layers="${LAYERS}" \
  "${YQ}" eval \
          --null-input '.[0] = {"Config": env(config), "RepoTags": "${repo_tags}" | envsubst | split(" ") | map(select(. != "")) , "Layers": env(layers) | map( "blobs/" + . + ".tar.gz") }' \
          --output-format json > "${STAGING_DIR}/manifest.json"
fi

# TODO: https://github.com/bazel-contrib/rules_oci/issues/217
cd "${STAGING_DIR}"
tar -cf "${TARBALL_PATH}" *
