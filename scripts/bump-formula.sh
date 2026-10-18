#!/usr/bin/env bash
#
# Render Formula/<name>.rb from the archives of a published GitHub release.
#
#   scripts/bump-formula.sh <owner/repo> <tag>
#
# The project is expected to attach `<name>-<tag>-<rust target>.tar.gz` archives
# and a single `SHA256SUMS` file to its release; everything that cannot be
# derived from the release itself lives in meta/<name>.json.
#
# Writes nothing when the rendered formula matches what is already committed, so
# the script is safe to re-run on the same tag.
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <owner/repo> <tag>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
repo=$1
tag=$2

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
name=${repo##*/}
meta="$root/meta/$name.json"
formula="$root/Formula/$name.rb"
version=${tag#v}

[[ -f $meta ]] || {
  echo "no metadata for $name: expected meta/$name.json" >&2
  exit 1
}

jq -e '.class and .desc and .homepage and .license and .bin
        and (.platforms | type == "object" and length > 0)' "$meta" >/dev/null || {
  echo "meta/$name.json must set class, desc, homepage, license, bin and platforms" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --dir "$tmp"

m() { # <jq path> -- a required field of the metadata
  jq -re "$1" "$meta"
}

target_of() { # <slot> -- the rust target for a platform slot, empty when absent
  jq -r --arg slot "$1" '.platforms[$slot] // ""' "$meta"
}

url_of() { # <rust target>
  printf 'https://github.com/%s/releases/download/%s/%s-%s-%s.tar.gz' \
    "$repo" "$tag" "$name" "$tag" "$1"
}

sha_of() { # <rust target> -- looked up in the release's SHA256SUMS
  local archive="$name-$tag-$1.tar.gz" sha
  sha=$(awk -v want="$archive" '$2 == want { print $1 }' "$tmp/SHA256SUMS")
  if [[ -z $sha ]]; then
    echo "release $tag of $repo has no archive $archive" >&2
    return 1
  fi
  printf '%s' "$sha"
}

source_stanza() { # <indent> <rust target>
  local indent=$1 target=$2 sha
  # Assigned on its own line: inside a printf argument a failing substitution
  # would be swallowed and leave an empty sha256 behind.
  sha=$(sha_of "$target") || exit 1
  printf '%surl "%s"\n' "$indent" "$(url_of "$target")"
  printf '%ssha256 "%s"\n' "$indent" "$sha"
}

# One `on_macos` / `on_linux` block. `url` and `sha256` have to live inside a
# nested `on_arm` / `on_intel` block — FormulaAudit/ComponentsOrder rejects them
# directly under `on_os`. A platform that ships only one architecture also gets a
# `depends_on arch:` guard, so the other one fails with "requires arm64
# architecture" instead of silently installing the wrong binary.
os_block() { # <macos|linux> <arm slot> <intel slot>
  local os=$1 arm intel
  arm=$(target_of "$2")
  intel=$(target_of "$3")

  [[ -n $arm || -n $intel ]] || return 0

  printf '  on_%s do\n' "$os"
  if [[ -z $intel ]]; then
    printf '    depends_on arch: :arm64\n\n'
  elif [[ -z $arm ]]; then
    printf '    depends_on arch: :x86_64\n\n'
  fi

  if [[ -n $arm ]]; then
    printf '    on_arm do\n'
    source_stanza '      ' "$arm"
    printf '    end\n'
    [[ -n $intel ]] && printf '\n'
  fi
  if [[ -n $intel ]]; then
    printf '    on_intel do\n'
    source_stanza '      ' "$intel"
    printf '    end\n'
  fi
  printf '  end\n\n'
}

# A formula with no top-level url fails to even load on a platform none of its
# `on_os` blocks match ("formula requires at least a URL"), which turns every
# brew command on an unsupported machine into a backtrace. So the first archive
# doubles as the default source; the blocks above override it per platform, and
# the guards keep an unsupported machine from installing it.
default_source() { # <fallback rust target>
  printf '  url "%s"\n' "$(url_of "$1")"
  printf '  version "%s"\n' "$version"
  printf '  sha256 "%s"\n' "$(sha_of "$1")"
}

# When a whole OS is missing, say so at load time for the same reason.
os_guard() {
  local macos=0 linux=0
  [[ -n $(target_of macos_arm) || -n $(target_of macos_intel) ]] && macos=1
  [[ -n $(target_of linux_arm) || -n $(target_of linux_intel) ]] && linux=1

  if [[ $macos == 1 && $linux == 0 ]]; then
    printf '  depends_on :macos\n\n'
  elif [[ $macos == 0 && $linux == 1 ]]; then
    printf '  depends_on :linux\n\n'
  fi
}

install_block() {
  local bin subcommand
  bin=$(m .bin)
  subcommand=$(jq -r '.completions.subcommand // ""' "$meta")

  printf '  def install\n'
  printf '    bin.install "%s"\n' "$bin"
  if [[ -n $subcommand ]]; then
    # The default shell parameter format passes the shell as a positional
    # argument: `<bin> <subcommand> zsh`, which is what clap_complete expects.
    printf '    generate_completions_from_executable(bin/"%s", "%s")\n' "$bin" "$subcommand"
  fi
  printf '  end\n\n'
}

test_block() {
  local bin args match expected
  bin=$(m .bin)
  args=$(jq -r '.test.args // "--version"' "$meta")
  match=$(jq -r '.test.match // "version"' "$meta")

  if [[ $match == version ]]; then
    expected='version.to_s'
  else
    expected="\"$match\""
  fi

  printf '  test do\n'
  printf '    assert_match %s, shell_output("#{bin}/%s %s")\n' "$expected" "$bin" "$args"
  printf '  end\n'
}

fallback=''
for slot in macos_arm macos_intel linux_intel linux_arm; do
  fallback=$(target_of "$slot")
  [[ -n $fallback ]] && break
done
[[ -n $fallback ]] || {
  echo "meta/$name.json lists no known platform slot" >&2
  exit 1
}

{
  printf '# This file is generated by scripts/bump-formula.sh; edit meta/%s.json instead.\n' "$name"
  printf 'class %s < Formula\n' "$(m .class)"
  printf '  desc "%s"\n' "$(m .desc)"
  printf '  homepage "%s"\n' "$(m .homepage)"
  default_source "$fallback"
  printf '  license "%s"\n\n' "$(m .license)"
  os_guard
  os_block macos macos_arm macos_intel
  os_block linux linux_arm linux_intel
  install_block
  test_block
  printf 'end\n'
} > "$tmp/formula.rb"

if [[ -f $formula ]] && cmp -s "$tmp/formula.rb" "$formula"; then
  echo "Formula/$name.rb is already at $version, nothing to do"
  exit 0
fi

mv "$tmp/formula.rb" "$formula"
echo "Formula/$name.rb updated to $version"
