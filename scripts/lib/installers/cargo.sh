# Driver: cargo. Installs Rust crate.
cargo_check()   { cargo install --list 2>/dev/null | grep -q "^$1 v"; }
cargo_install() { cargo install --locked "$1"; }
