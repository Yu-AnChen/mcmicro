#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <work_dir> <output_dir> <trace_file>" >&2
    exit 1
fi

work_dir_root="$1"
output_dir="$2"
trace="$3"

mkdir -p "$output_dir"

echo "Using trace: $trace"

grep 'MCMICRO:ASHLAR' "$trace" | awk '{print $2}' | while read -r hash; do
    work_dir=$(echo "${work_dir_root}/${hash}"*)
    if [[ ! -d "$work_dir" ]]; then
        echo "  [skip] work dir not found for hash: $hash" >&2
        continue
    fi
    find "$work_dir" -maxdepth 2 \( \
        -name '*-tissue-mask.jpg' -o \
        -name '*.ashlar.pkl'      -o \
        -name '*.ashlarqc*.pdf'   \
    \) | while read -r f; do
        cp "$f" "$output_dir/"
        echo "  copied: $(basename "$f")"
    done
done

echo "Done. Files in: $output_dir"
