#!/usr/bin/env bash
# Fetches the official MuJoCo release that viaform-mujoco pins into a cache outside the repo:
#   macOS: ~/Library/Caches/viaform-mujoco/<version>/mujoco.framework (from the .dmg)
#   Linux: ${XDG_CACHE_HOME:-~/.cache}/viaform-mujoco/<version>/{include,lib} (from the .tar.gz)
# Downloads only from github.com/google-deepmind/mujoco/releases and checks the SHA-256 pinned
# below. Never commit what this writes. Usage: mujoco/scripts/fetch-mujoco.sh
set -euo pipefail

VERSION="3.17.0"
SHA_MACOS="f719172d3ee09012840812b2e06524c7e66cd46d9952fae26f5fcd3658f52833"
SHA_LINUX_X86_64="b3246fc698ca27e05ce36047fe2b6866fe23c9e95a26b3a84dd48f011b85e3e4"
SHA_LINUX_AARCH64="55467a37b74e7d943899768aee820e6754a66811ae5ffa17d2768f0c40fc983a"
BASE="https://github.com/google-deepmind/mujoco/releases/download/${VERSION}"

case "$(uname -s)" in
  Darwin) CACHE="${HOME}/Library/Caches/viaform-mujoco" ;;
  Linux) CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/viaform-mujoco" ;;
  *) echo "fetch-mujoco: no prebuilt MuJoCo for $(uname -s) here; set MUJOCO_DIR by hand" >&2; exit 1 ;;
esac
DEST="${CACHE}/${VERSION}"
DL="${CACHE}/dl"
mkdir -p "${DL}"

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
fetch() {
  local name="$1" want="$2"
  if [ ! -f "${DL}/${name}" ] || [ "$(sha "${DL}/${name}")" != "${want}" ]; then
    curl -fsSL -o "${DL}/${name}.part" "${BASE}/${name}"
    mv "${DL}/${name}.part" "${DL}/${name}"
  fi
  local got
  got="$(sha "${DL}/${name}")"
  if [ "${got}" != "${want}" ]; then
    echo "fetch-mujoco: ${name} SHA-256 ${got}, expected ${want}" >&2
    rm -f "${DL}/${name}"
    exit 1
  fi
}

case "$(uname -s)" in
  Darwin)
    if [ -d "${DEST}/mujoco.framework" ]; then echo "${DEST}"; exit 0; fi
    NAME="mujoco-${VERSION}-macos-universal2.dmg"
    fetch "${NAME}" "${SHA_MACOS}"
    MNT="$(mktemp -d)"
    hdiutil attach -nobrowse -readonly -mountpoint "${MNT}" "${DL}/${NAME}" >/dev/null
    trap 'hdiutil detach "${MNT}" >/dev/null 2>&1 || true' EXIT
    mkdir -p "${DEST}"
    cp -R "${MNT}/mujoco.framework" "${DEST}/"
    cp "${MNT}/LICENSE" "${MNT}/THIRD_PARTY_NOTICES" "${DEST}/"
    # The simulate viewer, to open the exported .xml files.
    cp -R "${MNT}/MuJoCo.app" "${DEST}/" 2>/dev/null || true
    ;;
  Linux)
    if [ -d "${DEST}/lib" ]; then echo "${DEST}"; exit 0; fi
    case "$(uname -m)" in
      x86_64) ARCH="x86_64"; WANT="${SHA_LINUX_X86_64}" ;;
      aarch64|arm64) ARCH="aarch64"; WANT="${SHA_LINUX_AARCH64}" ;;
      *) echo "fetch-mujoco: no prebuilt MuJoCo for $(uname -m)" >&2; exit 1 ;;
    esac
    NAME="mujoco-${VERSION}-linux-${ARCH}.tar.gz"
    fetch "${NAME}" "${WANT}"
    TMP="$(mktemp -d)"
    tar -xzf "${DL}/${NAME}" -C "${TMP}"
    mkdir -p "${DEST}"
    cp -R "${TMP}/mujoco-${VERSION}/." "${DEST}/"
    rm -rf "${TMP}"
    ;;
esac
echo "${DEST}"
