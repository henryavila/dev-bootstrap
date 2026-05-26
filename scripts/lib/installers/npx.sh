# Driver: npx. Always-fresh — check() returns 1 so the engine always runs
# install(). The spec may include subcommands and args after the package
# name (e.g. "@scope/pkg@1.0 install --yes --flag"), which npx passes
# through to the package binary. verify() trusts the exit code.
npx_check()   { return 1; }
# shellcheck disable=SC2086  # intentional word-split: spec carries subcommand + args
npx_install() { npx -y $1; }
npx_verify()  { return 0; }
