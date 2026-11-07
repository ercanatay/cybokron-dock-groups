# Disk image helpers; source this file, don't run it. Works in bash and zsh.
#
#   attach_disk_image <image> <mountpoint|-> [readonly]
#   detach_disk_image <mountpoint>   (diskutil eject, falling back to hdiutil detach)
#   create_disk_image <folder> <volume-name> <output.dmg>   (compressed UDZO image from a folder)
#
# `hdiutil attach`/`create` are deprecated in favor of `diskutil image attach`/`create` (macOS 15.2+). The helper
# prefers diskutil when this macOS supports the subcommand and falls back to hdiutil otherwise
# (older runners). Both paths show their own error output; nothing is silenced. Which path ran is
# logged to stderr.

_diskimage_has_diskutil_attach() {
  diskutil image attach --help > /dev/null 2>&1
}

attach_disk_image() {
  local image="$1" mountpoint="${2:--}" mode="${3:-}"
  local -a args=()
  if _diskimage_has_diskutil_attach; then
    echo "diskimage: using 'diskutil image attach'" >&2
    args=(--nobrowse)
    [ "$mode" = "readonly" ] && args+=(--readOnly)
    [ "$mountpoint" != "-" ] && args+=(--mountPoint "$mountpoint")
    diskutil image attach "${args[@]}" "$image" >&2
  else
    echo "diskimage: 'diskutil image attach' unavailable, falling back to 'hdiutil attach'" >&2
    args=(-nobrowse)
    [ "$mode" = "readonly" ] && args+=(-readonly)
    [ "$mountpoint" != "-" ] && args+=(-mountpoint "$mountpoint")
    hdiutil attach "${args[@]}" "$image" >&2
  fi
}

# Detaches by mount point. `diskutil eject` (older than the image subcommands, and hdiutil detach
# is deprecated too) ejects the whole image; on failure it falls back to `hdiutil detach`.
detach_disk_image() {
  diskutil eject "$1" || hdiutil detach "$1"
}

_diskimage_has_diskutil_create() {
  diskutil image create from --help > /dev/null 2>&1
}

# Creates a compressed (UDZO) disk image from a folder. Prefers `diskutil image create from`,
# falls back to `hdiutil create -srcfolder`. The caller removes any existing output first.
create_disk_image() {
  local src="$1" volname="$2" out="$3"
  if _diskimage_has_diskutil_create; then
    echo "diskimage: using 'diskutil image create from'" >&2
    diskutil image create from --format UDZO --volumeName "$volname" "$src" "$out" >&2
  else
    echo "diskimage: 'diskutil image create' unavailable, falling back to 'hdiutil create'" >&2
    hdiutil create -volname "$volname" -srcfolder "$src" -format UDZO -ov "$out" >&2
  fi
}
