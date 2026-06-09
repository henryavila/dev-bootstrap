# shellcheck shell=bash
# ~/.bashrc.d/60-web-stack.sh — Laravel + PHP + service shortcuts.
# Mirror of the zsh fragment. See zshrc.d-60-web-stack.sh for comments.

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

if command -v php >/dev/null 2>&1; then
    _WEBSTACK_PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
else
    _WEBSTACK_PHP_VERSION=""
fi
alias srn='sudo service nginx restart'
alias ssn='sudo service nginx status'
if [ -n "$_WEBSTACK_PHP_VERSION" ]; then
    # shellcheck disable=SC2139
    alias srp="sudo service php${_WEBSTACK_PHP_VERSION}-fpm restart"
    # shellcheck disable=SC2139
    alias ssp="sudo service php${_WEBSTACK_PHP_VERSION}-fpm status"
fi
alias srr='sudo service redis restart'
alias ssr='sudo service redis status'
unset _WEBSTACK_PHP_VERSION
