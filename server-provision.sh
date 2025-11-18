#!/bin/bash

################################################################################
# Laravel Server Provisioning Script for Ubuntu 24.04
#
# This script sets up the BASE Laravel environment for hosting multiple sites:
# - PHP 8.3 with all required extensions
# - Composer
# - Node.js 21.x
# - MySQL 8.0 (server only, no databases)
# - Redis
# - Nginx (base configuration)
# - Supervisor (base installation)
# - Laravel user and deployment script
#
# Usage: sudo bash server_provision.sh
#
# After running this, use site-setup.sh to add individual Laravel sites.
# This script is idempotent - safe to run multiple times
################################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
APP_USER="laravel"
APP_GROUP="laravel"
PHP_VERSION="8.3"
NODE_VERSION="22.x"

################################################################################
# Helper Functions
################################################################################

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

################################################################################
# Installation Functions
################################################################################

update_system() {
    print_status "Updating system packages..."
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq software-properties-common curl git unzip zip
    print_success "System packages updated"
}

install_php() {
    print_status "Installing PHP ${PHP_VERSION}..."

    if command_exists php && php -v | grep -q "PHP ${PHP_VERSION}"; then
        print_warning "PHP ${PHP_VERSION} already installed, skipping..."
        return
    fi

    # Add Ondřej Surý PPA for PHP
    add-apt-repository -y ppa:ondrej/php
    apt-get update -qq

    # Install PHP and required extensions
    apt-get install -y -qq \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-soap \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-opcache

    # Configure PHP for production
    PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
    if [ -f "$PHP_INI" ]; then
        sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$PHP_INI"
        sed -i 's/^max_execution_time = .*/max_execution_time = 300/' "$PHP_INI"
        sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 100M/' "$PHP_INI"
        sed -i 's/^post_max_size = .*/post_max_size = 100M/' "$PHP_INI"

        # Enable opcache for production
        sed -i 's/^;*opcache.enable=.*/opcache.enable=1/' "$PHP_INI"
        sed -i 's/^;*opcache.memory_consumption=.*/opcache.memory_consumption=256/' "$PHP_INI"
        sed -i 's/^;*opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=16/' "$PHP_INI"
        sed -i 's/^;*opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' "$PHP_INI"
        sed -i 's/^;*opcache.validate_timestamps=.*/opcache.validate_timestamps=0/' "$PHP_INI"
    fi

    print_success "PHP ${PHP_VERSION} installed and configured"
}

install_composer() {
    print_status "Installing Composer..."

    if command_exists composer; then
        print_warning "Composer already installed, skipping..."
        return
    fi

    # Download and install Composer
    EXPECTED_CHECKSUM="$(curl -sS https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        print_error "Composer installer corrupt"
        rm composer-setup.php
        exit 1
    fi

    php composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
    rm composer-setup.php

    print_success "Composer installed"
}

install_nodejs() {
    print_status "Installing Node.js ${NODE_VERSION}..."

    if command_exists node && node -v | grep -q "v22"; then
        print_warning "Node.js 22.x already installed, skipping..."
        return
    fi

    # Add NodeSource repository
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs

    print_success "Node.js ${NODE_VERSION} installed"
}

install_mysql() {
    print_status "Installing MySQL 8.0..."

    if command_exists mysql; then
        print_warning "MySQL already installed, skipping..."
        return
    fi

    # Install MySQL
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq mysql-server

    # Start MySQL service
    systemctl start mysql
    systemctl enable mysql

    # Secure MySQL installation
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql -e "DROP DATABASE IF EXISTS test;"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mysql -e "FLUSH PRIVILEGES;"

    print_success "MySQL 8.0 installed and secured"
    print_warning "Use site-setup.sh to create databases for each site"
}

install_redis() {
    print_status "Installing Redis..."

    if command_exists redis-server; then
        print_warning "Redis already installed, skipping..."
        return
    fi

    apt-get install -y -qq redis-server

    # Configure Redis
    sed -i 's/^bind 127.0.0.1 ::1/bind 127.0.0.1/' /etc/redis/redis.conf
    sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf

    # Start and enable Redis
    systemctl start redis-server
    systemctl enable redis-server

    print_success "Redis installed and configured"
}

install_nginx() {
    print_status "Installing Nginx..."

    if command_exists nginx; then
        print_warning "Nginx already installed, skipping..."
        return
    fi

    apt-get install -y -qq nginx

    # Remove default site
    rm -f /etc/nginx/sites-enabled/default

    # Enable nginx to start on boot
    systemctl enable nginx

    # Start nginx
    systemctl start nginx

    print_success "Nginx installed (base configuration)"
    print_warning "Use site-setup.sh to configure individual sites"
}

setup_application_user() {
    print_status "Setting up Laravel user..."

    # Create laravel user if it doesn't exist
    if ! id "$APP_USER" &>/dev/null; then
        useradd -r -m -d /home/laravel -s /bin/bash "$APP_USER"
        print_success "Created user: $APP_USER"
    else
        print_warning "User $APP_USER already exists"
    fi

    # Add www-data to laravel group for Nginx access
    usermod -a -G "$APP_GROUP" www-data

    # Create /opt directory if it doesn't exist
    mkdir -p /opt
    chown root:root /opt
    chmod 755 /opt

    print_success "Laravel user configured"
    print_warning "Use site-setup.sh to create site directories"
}

setup_github_ssh() {
    print_status "Setting up GitHub SSH access for Laravel user..."

    SSH_DIR="/home/$APP_USER/.ssh"
    SSH_KEY="$SSH_DIR/id_ed25519"

    # Create .ssh directory if it doesn't exist
    if [ ! -d "$SSH_DIR" ]; then
        sudo -u "$APP_USER" mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
    fi

    # Generate SSH key if it doesn't exist
    if [ ! -f "$SSH_KEY" ]; then
        print_status "Generating SSH key..."
        sudo -u "$APP_USER" ssh-keygen -t ed25519 -C "laravel@$(hostname)" -f "$SSH_KEY" -N ""
        print_success "SSH key generated: $SSH_KEY"
    else
        print_warning "SSH key already exists at $SSH_KEY"
    fi

    # Add GitHub to known_hosts
    if [ ! -f "$SSH_DIR/known_hosts" ] || ! grep -q "github.com" "$SSH_DIR/known_hosts"; then
        print_status "Adding GitHub to known_hosts..."
        sudo -u "$APP_USER" ssh-keyscan -t ed25519 github.com >> "$SSH_DIR/known_hosts" 2>/dev/null
        chown "$APP_USER:$APP_GROUP" "$SSH_DIR/known_hosts"
        chmod 600 "$SSH_DIR/known_hosts"
        print_success "GitHub added to known_hosts"
    else
        print_warning "GitHub already in known_hosts"
    fi

    # Ensure all .ssh files have correct ownership and permissions
    chown -R "$APP_USER:$APP_GROUP" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR"/* 2>/dev/null || true

    print_success "GitHub SSH configured for $APP_USER"
}

configure_php_fpm_pool() {
    print_status "Configuring PHP-FPM pool for Laravel..."

    # Remove old laravel pool config if it exists (from previous script versions)
    LARAVEL_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/laravel.conf"
    if [ -f "$LARAVEL_POOL_CONF" ]; then
        rm -f "$LARAVEL_POOL_CONF"
        print_warning "Removed old laravel.conf pool file"
    fi

    # Modify the default www pool instead of creating a new one
    WWW_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

    if [ -f "$WWW_POOL_CONF" ]; then
        # Backup original if not already backed up
        if [ ! -f "${WWW_POOL_CONF}.original" ]; then
            cp "$WWW_POOL_CONF" "${WWW_POOL_CONF}.original"
        fi

        # Update the www pool to use laravel user
        sed -i "s/^user = www-data/user = ${APP_USER}/" "$WWW_POOL_CONF"
        sed -i "s/^group = www-data/group = ${APP_GROUP}/" "$WWW_POOL_CONF"

        # Increase performance settings if not already modified
        if ! grep -q "pm.max_children = 50" "$WWW_POOL_CONF"; then
            sed -i 's/^pm.max_children = .*/pm.max_children = 50/' "$WWW_POOL_CONF"
            sed -i 's/^pm.start_servers = .*/pm.start_servers = 10/' "$WWW_POOL_CONF"
            sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 5/' "$WWW_POOL_CONF"
            sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 20/' "$WWW_POOL_CONF"
        fi
    fi

    # Test PHP-FPM configuration
    if ! php-fpm${PHP_VERSION} -t 2>&1; then
        print_error "PHP-FPM configuration test failed"
        php-fpm${PHP_VERSION} -t 2>&1 | tail -20
        # Restore original if test fails
        if [ -f "${WWW_POOL_CONF}.original" ]; then
            cp "${WWW_POOL_CONF}.original" "$WWW_POOL_CONF"
        fi
        exit 1
    fi

    # Restart PHP-FPM
    if systemctl restart php${PHP_VERSION}-fpm; then
        print_success "PHP-FPM pool configured and restarted"
    else
        print_error "Failed to restart PHP-FPM. Checking logs..."
        journalctl -xeu php${PHP_VERSION}-fpm.service --no-pager -n 20
        # Restore original if restart fails
        if [ -f "${WWW_POOL_CONF}.original" ]; then
            cp "${WWW_POOL_CONF}.original" "$WWW_POOL_CONF"
            systemctl restart php${PHP_VERSION}-fpm
        fi
        exit 1
    fi
}

install_supervisor() {
    print_status "Installing Supervisor..."

    if command_exists supervisorctl; then
        print_warning "Supervisor already installed, skipping..."
        return
    fi

    apt-get install -y -qq supervisor

    # Start and enable supervisor
    systemctl start supervisor
    systemctl enable supervisor

    print_success "Supervisor installed"
    print_warning "Use site-setup.sh to configure Horizon for each site"
}

install_deployment_script() {
    print_status "Installing deployment script..."

    # Create the deployment script in /usr/local/bin
    cat > /usr/local/bin/laravel-site-deploy << 'DEPLOY_SCRIPT_EOF'
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

# Terminate Horizon (supervisor will automatically restart it)
printf '\nℹ️  Terminating Horizon (will auto-restart)\n'
sleep 3
php artisan horizon:terminate

printf '\n✅ Deployment completed successfully!\n'
printf 'Time: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '=========================================\n\n'
DEPLOY_SCRIPT_EOF

    # Make the script executable
    chmod +x /usr/local/bin/laravel-site-deploy

    # Configure sudo permissions for laravel user
    SUDOERS_FILE="/etc/sudoers.d/laravel-deploy"

    cat > "$SUDOERS_FILE" << EOF
# Allow laravel user to manage services without password for deployment
${APP_USER} ALL=(ALL) NOPASSWD: /bin/systemctl reload php8.3-fpm
${APP_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart php8.3-fpm
${APP_USER} ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl reread
${APP_USER} ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl update
${APP_USER} ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl start *
${APP_USER} ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl restart *
${APP_USER} ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl stop *
${APP_USER} ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl status *
EOF

    # Set proper permissions on sudoers file
    chmod 0440 "$SUDOERS_FILE"

    # Validate sudoers file
    visudo -c -f "$SUDOERS_FILE"

    print_success "Deployment script installed to /usr/local/bin/laravel-site-deploy"
    print_success "Sudo permissions configured for ${APP_USER}"
}

display_post_install_info() {
    SSH_PUB_KEY=$(cat /home/$APP_USER/.ssh/id_ed25519.pub 2>/dev/null || echo "SSH key not found")

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Server Provisioning Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}Installed Components:${NC}"
    echo "  ✓ PHP 8.3 with Laravel extensions"
    echo "  ✓ Composer"
    echo "  ✓ Node.js 21.x"
    echo "  ✓ MySQL 8.0"
    echo "  ✓ Redis"
    echo "  ✓ Nginx"
    echo "  ✓ Supervisor"
    echo "  ✓ Laravel user (laravel)"
    echo "  ✓ GitHub SSH key (for laravel user)"
    echo "  ✓ Deployment script (/usr/local/bin/laravel-site-deploy)"
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANT: Add SSH Key to GitHub${NC}"
    echo ""
    echo -e "${BLUE}Public SSH Key:${NC}"
    echo ""
    echo "$SSH_PUB_KEY"
    echo ""
    echo -e "${YELLOW}To add this key to GitHub:${NC}"
    echo "  1. Go to https://github.com/settings/keys"
    echo "  2. Click 'New SSH key'"
    echo "  3. Paste the public key above"
    echo "  4. Give it a title like: 'Production Server - $(hostname)'"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo ""
    echo "1. Copy site-setup.sh to the server:"
    echo -e "   ${BLUE}scp site-setup.sh root@your-server:/root/${NC}"
    echo ""
    echo "2. Run site-setup.sh for each Laravel site:"
    echo -e "   ${BLUE}sudo bash /root/site-setup.sh app.example.com${NC}"
    echo -e "   ${BLUE}sudo bash /root/site-setup.sh staging.example.com${NC}"
    echo ""
    echo "3. This will create:"
    echo "   - Site directory in /opt/{sitename}"
    echo "   - MySQL database and user"
    echo "   - Nginx configuration"
    echo "   - Supervisor Horizon configuration"
    echo ""
    echo "4. Then deploy your Laravel app using:"
    echo -e "   ${BLUE}./site-deploy.sh app.example.com${NC}"
    echo ""
    echo -e "${GREEN}Server is ready for Laravel sites!${NC}"
    echo ""
}

verify_provisioning() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Verifying Provisioning${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    local all_checks_passed=true

    # Check 1: PHP 8.3 installed
    if command_exists php && php -v | grep -q "PHP 8.3"; then
        print_success "✓ PHP 8.3 installed"
    else
        print_error "✗ PHP 8.3 not installed"
        all_checks_passed=false
    fi

    # Check 2: Composer installed
    if command_exists composer; then
        print_success "✓ Composer installed"
    else
        print_error "✗ Composer not installed"
        all_checks_passed=false
    fi

    # Check 3: Node.js installed
    if command_exists node && node -v | grep -q "v22"; then
        print_success "✓ Node.js 22.x installed"
    else
        print_error "✗ Node.js 22.x not installed"
        all_checks_passed=false
    fi

    # Check 4: MySQL installed and running
    if command_exists mysql && systemctl is-active --quiet mysql; then
        print_success "✓ MySQL installed and running"
    else
        print_error "✗ MySQL not installed or not running"
        all_checks_passed=false
    fi

    # Check 5: Redis installed and running
    if command_exists redis-server && systemctl is-active --quiet redis-server; then
        print_success "✓ Redis installed and running"
    else
        print_error "✗ Redis not installed or not running"
        all_checks_passed=false
    fi

    # Check 6: Nginx installed and running
    if command_exists nginx && systemctl is-active --quiet nginx; then
        print_success "✓ Nginx installed and running"
    else
        print_error "✗ Nginx not installed or not running"
        all_checks_passed=false
    fi

    # Check 7: Supervisor installed and running
    if command_exists supervisorctl && systemctl is-active --quiet supervisor; then
        print_success "✓ Supervisor installed and running"
    else
        print_error "✗ Supervisor not installed or not running"
        all_checks_passed=false
    fi

    # Check 8: Laravel user exists
    if id "$APP_USER" &>/dev/null; then
        print_success "✓ Laravel user created: $APP_USER"
    else
        print_error "✗ Laravel user missing: $APP_USER"
        all_checks_passed=false
    fi

    # Check 9: SSH key generated
    if [ -f "/home/$APP_USER/.ssh/id_ed25519" ]; then
        print_success "✓ SSH key generated for $APP_USER"
    else
        print_error "✗ SSH key missing for $APP_USER"
        all_checks_passed=false
    fi

    # Check 10: Deployment script installed
    if [ -f "/usr/local/bin/laravel-site-deploy" ] && [ -x "/usr/local/bin/laravel-site-deploy" ]; then
        print_success "✓ Deployment script installed"
    else
        print_error "✗ Deployment script missing or not executable"
        all_checks_passed=false
    fi

    # Check 11: PHP-FPM running
    if systemctl is-active --quiet php8.3-fpm; then
        print_success "✓ PHP-FPM 8.3 running"
    else
        print_error "✗ PHP-FPM 8.3 not running"
        all_checks_passed=false
    fi

    # Check 12: Sudoers file for laravel user
    if [ -f "/etc/sudoers.d/laravel-deploy" ]; then
        print_success "✓ Sudo permissions configured for $APP_USER"
    else
        print_error "✗ Sudo permissions not configured for $APP_USER"
        all_checks_passed=false
    fi

    echo ""
    if [ "$all_checks_passed" = true ]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}✓ All Provisioning Checks Passed!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        return 0
    else
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}✗ Some Provisioning Checks Failed${NC}"
        echo -e "${RED}========================================${NC}"
        echo ""
        echo -e "${YELLOW}Please review the errors above and fix them before proceeding.${NC}"
        echo ""
        return 1
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    print_status "Starting Laravel server provisioning for Ubuntu 24.04..."
    echo ""

    check_root

    update_system
    install_php
    install_composer
    install_nodejs
    install_mysql
    install_redis
    setup_application_user
    setup_github_ssh
    install_nginx
    configure_php_fpm_pool
    install_supervisor
    install_deployment_script

    display_post_install_info

    verify_provisioning
}

# Run main function
main
