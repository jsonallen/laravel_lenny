#!/bin/bash

################################################################################
# Laravel Site Setup Script
#
# This script sets up an individual Laravel site on an already-provisioned server.
# Run this after server_provision.sh to add each Laravel site.
#
# Usage: sudo bash site-setup.sh <domain>
# Example: sudo bash site-setup.sh app.example.com
#
# This script is idempotent - safe to run multiple times
################################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
# Validation
################################################################################

# Check for required domain parameter
if [ -z "$1" ]; then
    echo -e "${RED}[ERROR]${NC} Domain name is required"
    echo -e "Usage: sudo bash site-setup.sh <domain>"
    echo -e "Example: sudo bash site-setup.sh app.example.com"
    exit 1
fi

DOMAIN="$1"

# Validate domain format (basic check)
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    print_error "Invalid domain format: $DOMAIN"
    exit 1
fi

# Configuration variables
SITE_NAME=$(echo "$DOMAIN" | tr '.' '_')  # app.example.com -> app_example_com
SITE_DIR="/opt/${SITE_NAME}"
APP_USER="laravel"
APP_GROUP="laravel"
PHP_VERSION="8.3"

# Database configuration (replace hyphens with underscores for MySQL compatibility)
DB_NAME=$(echo "${SITE_NAME}" | tr '-' '_')  # MySQL doesn't allow hyphens in DB names
DB_CRED_FILE="/root/.${SITE_NAME}_mysql_credentials"

# Determine database credentials (idempotency check)
if [ -f "$DB_CRED_FILE" ]; then
    # Load existing credentials from file
    DB_USER=$(grep "MySQL User:" "$DB_CRED_FILE" | cut -d' ' -f3)
    DB_PASSWORD=$(grep "MySQL Password:" "$DB_CRED_FILE" | cut -d' ' -f3)
else
    # Check if database already exists and has a user assigned
    EXISTING_USER=$(mysql -se "SELECT DISTINCT User FROM mysql.db WHERE Db='${DB_NAME}' AND User LIKE 'laravel_%' LIMIT 1" 2>/dev/null || echo "")

    if [ -n "$EXISTING_USER" ]; then
        # Database exists with a user - we cannot recover the password, must fail
        print_error "Database ${DB_NAME} exists with user ${EXISTING_USER}, but credentials file is missing!"
        print_error "Cannot recover password. Options:"
        print_error "  1. Restore credentials file to: ${DB_CRED_FILE}"
        print_error "  2. Drop database and user to start fresh:"
        print_error "     mysql -e \"DROP DATABASE ${DB_NAME}; DROP USER '${EXISTING_USER}'@'localhost';\""
        exit 1
    fi

    # Generate new credentials for fresh setup
    DB_USER="laravel_$(shuf -i 1000-9999 -n 1)"
    DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
fi

# Nginx configuration
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"

# Supervisor configuration
SUPERVISOR_CONF="/etc/supervisor/conf.d/${SITE_NAME}-horizon.conf"

################################################################################
# Setup Functions
################################################################################

check_root

print_status "Setting up Laravel site: $DOMAIN"
print_status "Site directory: $SITE_DIR"
echo ""

create_site_directory() {
    print_status "Creating site directory structure..."

    # Create main directory (empty, for git clone)
    mkdir -p "$SITE_DIR"

    # Set ownership
    chown -R "$APP_USER:$APP_GROUP" "$SITE_DIR"

    print_success "Site directory created: $SITE_DIR"
    print_warning "Directory is empty and ready for git clone"
}

create_database() {
    print_status "Creating MySQL database and user..."

    # Check if MySQL is installed
    if ! command_exists mysql; then
        print_error "MySQL is not installed. Run server_provision.sh first."
        exit 1
    fi

    # Check if database already exists
    DB_EXISTS=$(mysql -se "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}'" 2>/dev/null)

    if [ -n "$DB_EXISTS" ]; then
        print_warning "Database ${DB_NAME} already exists, skipping database creation..."
    else
        # Create database
        mysql -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        print_success "Database ${DB_NAME} created"
    fi

    # Check if user already exists
    USER_EXISTS=$(mysql -se "SELECT User FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost'" 2>/dev/null)

    if [ -n "$USER_EXISTS" ]; then
        print_warning "User ${DB_USER} already exists, skipping user creation..."
    else
        # Create user
        mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
        print_success "User ${DB_USER} created"
    fi

    # Grant privileges (safe to run multiple times)
    mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    # Save credentials to file if it doesn't exist
    if [ ! -f "$DB_CRED_FILE" ]; then
        cat > "$DB_CRED_FILE" << EOF
Site: ${DOMAIN}
MySQL Database: ${DB_NAME}
MySQL User: ${DB_USER}
MySQL Password: ${DB_PASSWORD}
MySQL Host: localhost
Created: $(date '+%Y-%m-%d %H:%M:%S')
EOF
        chmod 600 "$DB_CRED_FILE"
        print_success "Credentials saved to ${DB_CRED_FILE}"
    else
        print_warning "Credentials file already exists at ${DB_CRED_FILE}"
    fi
}

configure_nginx() {
    print_status "Configuring Nginx for $DOMAIN..."

    # Check if Nginx is installed
    if ! command_exists nginx; then
        print_error "Nginx is not installed. Run server_provision.sh first."
        exit 1
    fi

    # Create Nginx server block
    cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};
    root ${SITE_DIR}/public;

    index index.php index.html;

    charset utf-8;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Logging
    access_log /var/log/nginx/${DOMAIN}-access.log;
    error_log /var/log/nginx/${DOMAIN}-error.log;

    # Main location
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # PHP-FPM configuration
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;

        # Increase timeouts for long-running requests
        fastcgi_read_timeout 300;
    }

    # Deny access to hidden files
    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

    # Enable site
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

    # Test nginx configuration
    if ! nginx -t 2>&1; then
        print_error "Nginx configuration test failed"
        rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
        exit 1
    fi

    # Reload nginx
    systemctl reload nginx

    print_success "Nginx configured for $DOMAIN"
}

configure_supervisor() {
    print_status "Configuring Supervisor for Horizon..."

    # Check if Supervisor is installed
    if ! command_exists supervisorctl; then
        print_error "Supervisor is not installed. Run server_provision.sh first."
        exit 1
    fi

    # Create Horizon supervisor configuration
    cat > "$SUPERVISOR_CONF" << EOF
[program:${SITE_NAME}-horizon]
process_name=%(program_name)s_%(process_num)02d
command=php ${SITE_DIR}/artisan horizon
directory=${SITE_DIR}
user=${APP_USER}
numprocs=1
autostart=true
autorestart=true
startsecs=1
redirect_stderr=true
stdout_logfile=${SITE_DIR}/storage/logs/horizon.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=3
stopwaitsecs=5
stopsignal=SIGTERM
stopasgroup=true
killasgroup=true
EOF

    print_success "Supervisor config file created: ${SUPERVISOR_CONF}"
    print_warning "Supervisor will be configured after first deployment (directories must exist first)"
    print_warning "After deployment, run: sudo supervisorctl reread && sudo supervisorctl update"
}

setup_cron() {
    print_status "Checking Laravel scheduler cron job..."

    # Check if a scheduler cron job exists for any site
    if crontab -u "$APP_USER" -l 2>/dev/null | grep -q "artisan schedule:run"; then
        print_warning "Laravel scheduler cron job already exists"
        return
    fi

    # Add Laravel scheduler to crontab (runs for all sites)
    (crontab -u "$APP_USER" -l 2>/dev/null; echo "* * * * * cd /opt && for dir in */; do [ -f \"\$dir/artisan\" ] && cd \"\$dir\" && php artisan schedule:run >> /dev/null 2>&1; cd /opt; done") | crontab -u "$APP_USER" -

    print_success "Laravel scheduler cron job configured"
}

display_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Site Setup Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}Domain:${NC} $DOMAIN"
    echo -e "${BLUE}Site Directory:${NC} $SITE_DIR"
    echo -e "${BLUE}Nginx Config:${NC} $NGINX_CONF"
    echo ""
    echo -e "${YELLOW}Database Credentials:${NC}"
    echo -e "  Database: $DB_NAME"
    echo -e "  User: $DB_USER"
    echo -e "  Password: $DB_PASSWORD"
    echo -e "  Host: localhost"
    echo ""
    echo -e "  ${YELLOW}⚠️  Credentials saved to: ${DB_CRED_FILE}${NC}"
    echo -e "  ${YELLOW}⚠️  Delete this file after copying to .env for security${NC}"
    echo -e "  ${YELLOW}⚠️  Command: rm ${DB_CRED_FILE}${NC}"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo ""
    echo "1. Clone your Laravel repository:"
    echo -e "   ${BLUE}cd ${SITE_DIR}${NC}"
    echo -e "   ${BLUE}sudo -u laravel git clone <your-repo-url> .${NC}"
    echo -e "   ${YELLOW}(Note the '.' at the end - clones into existing directory)${NC}"
    echo ""
    echo "2. Install Composer dependencies:"
    echo -e "   ${BLUE}cd ${SITE_DIR}${NC}"
    echo -e "   ${BLUE}sudo -u laravel composer install --no-dev --optimize-autoloader${NC}"
    echo ""
    echo "3. Configure .env file:"
    echo -e "   ${BLUE}sudo -u laravel cp ${SITE_DIR}/.env.example ${SITE_DIR}/.env${NC}"
    echo -e "   ${BLUE}sudo -u laravel nano ${SITE_DIR}/.env${NC}"
    echo ""
    echo "   Update these values in .env:"
    echo ""
    echo "APP_URL=https://${DOMAIN}"
    echo ""
    echo "DB_CONNECTION=mysql"
    echo "DB_HOST=127.0.0.1"
    echo "DB_PORT=3306"
    echo "DB_DATABASE=${DB_NAME}"
    echo "DB_USERNAME=${DB_USER}"
    echo "DB_PASSWORD=${DB_PASSWORD}"
    echo ""
    echo "4. Generate application key:"
    echo -e "   ${BLUE}sudo -u laravel php ${SITE_DIR}/artisan key:generate${NC}"
    echo ""
    echo "5. Deploy using the deployment script:"
    echo -e "   ${BLUE}./site-deploy.sh ${DOMAIN}${NC}"
    echo -e "   ${YELLOW}(Deployment will automatically configure Supervisor and start Horizon)${NC}"
    echo ""
    echo -e "${GREEN}Site is ready for deployment!${NC}"
    echo ""
}

################################################################################
# Main Execution
################################################################################

create_site_directory
create_database
configure_nginx
configure_supervisor
setup_cron

display_summary
