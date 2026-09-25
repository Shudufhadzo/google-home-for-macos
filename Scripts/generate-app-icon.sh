#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_image="$project_dir/Resources/HomeSpeakerIconSource.png"
temp_dir="$(mktemp -d /private/tmp/home-speaker-icon.XXXXXX)"
trap 'rm -rf "$temp_dir"' EXIT
iconset_dir="$temp_dir/HomeSpeaker.iconset"
mkdir -p "$iconset_dir"

for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$source_image" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -s format png -z "$double_size" "$double_size" "$source_image" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$project_dir/Resources/HomeSpeakerIcon.icns"
echo "$project_dir/Resources/HomeSpeakerIcon.icns"
