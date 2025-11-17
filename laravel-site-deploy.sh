#!/bin/bash

################################################################################
# Laravel Site Deployment Script
#
# This script runs ON THE SERVER to deploy Laravel applications
# Installed to: /usr/local/bin/laravel-site-deploy
#
# Usage: laravel-site-deploy /opt/example_com [branch]
#
# Based on Laravel Forge deployment process
################################################################################

set -e  # Exit on error

# Check for required arguments
if [ -z "$1" ]; then
    echo "Error: Site directory path required"
    echo "Usage: laravel-site-deploy /path/to/site [branch]"
    exit 1
fi

SITE_DIR="$1"
BRANCH="${2:-main}"  # Default to main branch if not specified

# Verify site directory exists
if [ ! -d "$SITE_DIR" ]; then
    echo "Error: Site directory does not exist: $SITE_DIR"
    exit 1
fi

# Change to site directory
cd "$SITE_DIR" || exit 1

echo "========================================="
echo "Laravel Deployment"
echo "========================================="
echo "Site: $SITE_DIR"
echo "Branch: $BRANCH"
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="
echo ""

# Git pull
printf 'ℹ️  Pulling latest code from Git\n'
git pull origin "$BRANCH"

# Composer install
printf '\nℹ️  Installing Composer dependencies\n'
composer install --no-interaction --prefer-dist --optimize-autoloader --no-dev

# FPM reload with file lock (prevents concurrent reloads)
printf '\nℹ️  Reloading PHP-FPM\n'
( flock -w 10 9 || exit 1
    sudo systemctl reload php8.3-fpm
) 9>/tmp/fpmlock

# NPM install and build
printf '\nℹ️  Installing NPM dependencies based on package-lock.json\n'
npm ci

printf '\nℹ️  Generating JS App files\n'
npm run build

# Database migrations
printf '\nℹ️  Running database migrations\n'
php artisan migrate --force

# Queue restart
printf '\nℹ️  Restarting queue workers\n'
php artisan queue:restart

# Clear caches
printf '\nℹ️  Clearing caches\n'
php artisan cache:clear
php artisan config:clear
php artisan optimize

# Filament optimizations
printf '\nℹ️  Caching Filament components\n'
php artisan filament:cache-components

printf '\nℹ️  Optimizing Filament\n'
php artisan filament:optimize

# Reload Supervisor configuration (for first deployment)
printf '\nℹ️  Reloading Supervisor configuration\n'
sudo supervisorctl reread
sudo supervisorctl update

# Get the site name from the path for Horizon process name
SITE_NAME=$(basename "$SITE_DIR")

# Check if Horizon is running, start it if not
HORIZON_STATUS=$(sudo supervisorctl status "${SITE_NAME}-horizon" 2>/dev/null | awk '{print $2}')
if [ "$HORIZON_STATUS" = "STOPPED" ] || [ "$HORIZON_STATUS" = "FATAL" ]; then
    printf '\nℹ️  Starting Horizon\n'
    sudo supervisorctl start "${SITE_NAME}-horizon"
else
    # Terminate Horizon (supervisor will automatically restart it)
    printf '\nℹ️  Restarting Horizon\n'
    sudo supervisorctl restart "${SITE_NAME}-horizon"
fi

printf '\n✅ Deployment completed successfully!\n'
printf 'Time: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '=========================================\n\n'
