#!/usr/bin/env bash

set -euo pipefail
umask 077

BINARY=""
KEY=""

fail() {
  printf 'read-macho-info-plist: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: scripts/read-macho-info-plist.sh --binary PATH [--key PLIST_KEY]\n'
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$BINARY" == /* && -f "$BINARY" && ! -L "$BINARY" ]] || fail 'invalid binary path'
architectures="$(/usr/bin/lipo -archs "$BINARY")" || fail 'could not read architectures'
work_dir="$(mktemp -d /tmp/peekaboo-macho-info.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
expected_value=""
for architecture in $architectures; do
  thin_binary="$work_dir/thin-$architecture"
  /usr/bin/lipo -thin "$architecture" "$BINARY" -output "$thin_binary" || fail 'could not thin architecture'
  load_commands="$(/usr/bin/otool -l "$thin_binary")" || fail 'could not inspect Mach-O load commands'
  section="$(/usr/bin/awk '
    $1 == "sectname" { wanted = ($2 == "__info_plist"); segment = ""; size = "" }
    wanted && $1 == "segname" { segment = $2 }
    wanted && segment == "__TEXT" && $1 == "size" { size = $2 }
    wanted && segment == "__TEXT" && $1 == "offset" { result = size " " $2; found += 1; wanted = 0 }
    END { if (found == 1) print result; else exit 1 }
  ' <<<"$load_commands")" || fail "Mach-O $architecture must have exactly one __TEXT,__info_plist section"
  size_hex="${section%% *}"
  offset="${section#* }"
  [[ "$size_hex" =~ ^0x[0-9a-fA-F]+$ && "$offset" =~ ^[0-9]+$ ]] || fail 'invalid section metadata'
  size=$((size_hex))
  ((size > 0)) || fail 'empty Info.plist section'

  plist_file="$work_dir/Info-$architecture.plist"
  /bin/dd if="$thin_binary" of="$plist_file" bs=1 skip="$offset" count="$size" 2>/dev/null
  /usr/bin/plutil -lint "$plist_file" >/dev/null || fail 'embedded Info.plist is invalid'
  if [[ -n "$KEY" ]]; then
    current_value="$(/usr/bin/plutil -extract "$KEY" raw -o - "$plist_file")"
  else
    current_value="$(/bin/cat "$plist_file")"
  fi
  if [[ -z "$expected_value" ]]; then
    expected_value="$current_value"
  elif [[ "$current_value" != "$expected_value" ]]; then
    fail "embedded Info.plist differs for architecture $architecture"
  fi
done
printf '%s\n' "$expected_value"
