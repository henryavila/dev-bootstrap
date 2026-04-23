# shellcheck shell=bash
# ~/.zshrc.d/60-web-stack.sh — Laravel + PHP + service shortcuts.
# Deployed only when the user opted into INCLUDE_WEBSTACK=1, so aliases
# for tools that aren't installed never pollute other profiles.

# Laravel / Composer — everyday commands shortened.
alias art='php artisan'
alias artisan='php artisan'
alias cdump='composer dump-autoload -o'
alias cinst='composer install'
alias cup='composer update'
alias fresh='php artisan migrate:fresh'
alias migrate='php artisan migrate'
alias refresh='php artisan migrate:refresh'
alias rollback='php artisan migrate:rollback'
alias seed='php artisan db:seed'
alias 'db:reset'='php artisan migrate:reset && php artisan migrate --seed'
alias aserve='php artisan serve --quiet &'
alias dusk='php artisan dusk'
alias phpunit='./vendor/bin/phpunit'
alias pu='./vendor/bin/phpunit'
alias puf='./vendor/bin/phpunit --filter'
alias pud='./vendor/bin/phpunit --debug'

# Service restart/status — PHP version detected at load time so
# `srp`/`ssp` always target the CURRENT default PHP. Uses `service`
# which works on both systemd (Ubuntu/WSL) and SysV init.
if command -v php >/dev/null 2>&1; then
    _WEBSTACK_PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
else
    _WEBSTACK_PHP_VERSION=""
fi
alias srn='sudo service nginx restart'
alias ssn='sudo service nginx status'
if [ -n "$_WEBSTACK_PHP_VERSION" ]; then
    # shellcheck disable=SC2139  # intentional: $_WEBSTACK_PHP_VERSION expands at load time
    alias srp="sudo service php${_WEBSTACK_PHP_VERSION}-fpm restart"
    # shellcheck disable=SC2139
    alias ssp="sudo service php${_WEBSTACK_PHP_VERSION}-fpm status"
fi
alias srr='sudo service redis restart'
alias ssr='sudo service redis status'
unset _WEBSTACK_PHP_VERSION
