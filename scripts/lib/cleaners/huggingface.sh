# shellcheck shell=bash
# Cleaner: huggingface — downloaded HF models/datasets cache. Tier-2: large and
# re-downloaded on next use.
cleaner_huggingface_tier()    { echo 2; }
cleaner_huggingface_desc()    { echo "HuggingFace model/dataset cache"; }
cleaner_huggingface_applies() { _clean_paths_applies "$HOME/.cache/huggingface"; }
cleaner_huggingface_measure() { _clean_bytes_of      "$HOME/.cache/huggingface"; }
cleaner_huggingface_clean()   { _clean_paths_clean   "$HOME/.cache/huggingface"; }
