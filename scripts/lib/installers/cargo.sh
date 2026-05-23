# Driver: cargo. Installs Rust crate.
# check uses awk literal-substring match (regex metachars in pkg names like
# `+` `.` `*` would false-positive with the previous `grep -q "^$1 v"`).
# Note: END runs after any `exit` — use a flag pattern, not `exit 0` in body.
cargo_check()   { cargo install --list 2>/dev/null \
    | awk -v pkg="$1" 'index($0, pkg " v") == 1 { found=1 } END { exit !found }'; }
cargo_install() { cargo install --locked "$1"; }
