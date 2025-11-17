#!/bin/bash

################################################################################
# Let's Encrypt SSL Setup Script
#
# This script sets up free SSL certificates from Let's Encrypt for a Laravel site
# Run this after site-setup.sh to enable HTTPS
#
# Usage: sudo bash site-letsencrypt-ssl.sh <domain> <email>
# Example: sudo bash site-letsencrypt-ssl.sh app.example.com admin@example.com
#
# IMPORTANT: DNS must point to this server BEFORE running this script!
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

check_root

# Check for required arguments
if [ -z "$1" ] || [ -z "$2" ]; then
    echo -e "${RED}[ERROR]${NC} Domain and email are required"
    echo -e "Usage: sudo bash site-letsencrypt-ssl.sh <domain> <email>"
    echo -e "Example: sudo bash site-letsencrypt-ssl.sh app.example.com admin@example.com"
    exit 1
fi

DOMAIN="$1"
EMAIL="$2"

# Validate domain format
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    print_error "Invalid domain format: $DOMAIN"
    exit 1
fi

# Validate email format
if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    print_error "Invalid email format: $EMAIL"
    exit 1
fi

SITE_NAME=$(echo "$DOMAIN" | tr '.' '_')
SITE_DIR="/opt/${SITE_NAME}"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"

# Check if site exists
if [ ! -d "$SITE_DIR" ]; then
    print_error "Site directory does not exist: $SITE_DIR"
    print_error "Run site-setup.sh first!"
    exit 1
fi

if [ ! -f "$NGINX_CONF" ]; then
    print_error "Nginx configuration does not exist: $NGINX_CONF"
    print_error "Run site-setup.sh first!"
    exit 1
fi

################################################################################
# DNS Warning
################################################################################

# Get server's public IP
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "Unable to determine")

echo ""
echo -e "${RED}========================================${NC}"
echo -e "${RED}⚠️  DNS REQUIREMENT WARNING ⚠️${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo -e "${YELLOW}BEFORE running this script, you MUST ensure:${NC}"
echo ""
echo -e "1. DNS A record for ${BLUE}${DOMAIN}${NC} points to:"
echo -e "   ${GREEN}${SERVER_IP}${NC}"
echo ""
echo -e "2. DNS changes have propagated (can take up to 24-48 hours)"
echo ""
echo -e "3. Port 80 and 443 are open in your firewall"
echo ""
echo -e "${YELLOW}Let's Encrypt will verify domain ownership by making an HTTP${NC}"
echo -e "${YELLOW}request to your domain. If DNS is not configured correctly,${NC}"
echo -e "${YELLOW}certificate issuance will FAIL.${NC}"
echo ""
echo -e "${BLUE}To verify DNS:${NC}"
echo -e "  dig +short ${DOMAIN}"
echo -e "  nslookup ${DOMAIN}"
echo ""
echo -e "${RED}========================================${NC}"
echo ""

# Check DNS resolution
DNS_IP=$(dig +short "$DOMAIN" 2>/dev/null | tail -n1)
if [ -n "$DNS_IP" ]; then
    if [ "$DNS_IP" = "$SERVER_IP" ]; then
        print_success "DNS check passed: $DOMAIN resolves to $SERVER_IP"
    else
        print_warning "DNS mismatch: $DOMAIN resolves to $DNS_IP, but server IP is $SERVER_IP"
        echo -e "${YELLOW}This may be okay if you're behind a load balancer or proxy.${NC}"
    fi
else
    print_warning "Could not resolve DNS for $DOMAIN"
    echo -e "${YELLOW}Make sure DNS is configured before proceeding.${NC}"
fi

echo ""
read -p "Have you verified that DNS is configured correctly? (yes/no) " -r
echo
if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
    echo -e "${YELLOW}Aborted. Configure DNS and try again.${NC}"
    exit 0
fi

################################################################################
# Install Certbot
################################################################################

install_certbot() {
    print_status "Checking for Certbot..."

    if command_exists certbot; then
        print_success "Certbot already installed"
        certbot --version
        return
    fi

    print_status "Installing Certbot..."

    # Install snapd if not present
    if ! command_exists snap; then
        apt-get update -qq
        apt-get install -y -qq snapd
        systemctl enable --now snapd.socket
        sleep 5
    fi

    # Install certbot via snap (recommended by Let's Encrypt)
    snap install core
    snap refresh core
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/bin/certbot

    print_success "Certbot installed"
}

################################################################################
# Generate Certificate
################################################################################

generate_certificate() {
    print_status "Generating Let's Encrypt SSL certificate for $DOMAIN..."

    # Check if certificate already exists
    if certbot certificates -d "$DOMAIN" 2>/dev/null | grep -q "Certificate Name: $DOMAIN"; then
        print_warning "Certificate already exists for $DOMAIN"
        echo ""
        echo "This will renew/update the existing certificate."
        echo "This is useful if:"
        echo "  - Server IP changed (update DNS first!)"
        echo "  - Certificate is expiring soon"
        echo "  - You need to update configuration"
        echo ""
        read -p "Continue with certificate renewal? (yes/no) " -r
        echo
        if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
            print_warning "Skipping certificate generation"
            return
        fi
        CERTBOT_ARGS="--force-renewal"
    else
        CERTBOT_ARGS=""
    fi

    # Run certbot with nginx plugin
    # --nginx: Use Nginx plugin (automatically configures Nginx)
    # --non-interactive: Don't ask questions
    # --agree-tos: Agree to terms of service
    # --redirect: Enable HTTP to HTTPS redirect
    # --force-renewal: Force renewal if certificate exists
    # --email: Contact email for renewal notices
    # -d: Domain name

    certbot --nginx \
        --non-interactive \
        --agree-tos \
        --redirect \
        --hsts \
        --staple-ocsp \
        --email "$EMAIL" \
        $CERTBOT_ARGS \
        -d "$DOMAIN"

    print_success "SSL certificate generated and Nginx configured!"
}

################################################################################
# Verify Setup
################################################################################

verify_setup() {
    print_status "Verifying SSL setup..."

    # Test Nginx configuration
    if nginx -t 2>&1 | grep -q "successful"; then
        print_success "Nginx configuration is valid"
    else
        print_error "Nginx configuration test failed"
        nginx -t
        exit 1
    fi

    # Reload Nginx
    systemctl reload nginx
    print_success "Nginx reloaded"

    # Check certificate info
    CERT_INFO=$(certbot certificates -d "$DOMAIN" 2>/dev/null)
    if echo "$CERT_INFO" | grep -q "VALID"; then
        print_success "Certificate is valid"
        echo "$CERT_INFO" | grep -E "(Certificate Name|Domains|Expiry Date)"
    fi

    # Check auto-renewal
    if systemctl is-active --quiet snap.certbot.renew.timer; then
        print_success "Auto-renewal timer is active"
    else
        print_warning "Auto-renewal timer may not be active"
    fi

    # Test renewal (dry run)
    print_status "Testing certificate renewal (dry run)..."
    if certbot renew --dry-run --quiet; then
        print_success "Renewal test passed"
    else
        print_warning "Renewal test failed - check configuration"
    fi
}

################################################################################
# Display Summary
################################################################################

display_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}SSL Setup Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}Domain:${NC} $DOMAIN"
    echo -e "${BLUE}Email:${NC} $EMAIL"
    echo -e "${BLUE}Certificate Location:${NC} /etc/letsencrypt/live/${DOMAIN}/"
    echo ""
    echo -e "${YELLOW}What was configured:${NC}"
    echo "  ✓ SSL certificate generated from Let's Encrypt"
    echo "  ✓ Nginx configured for HTTPS"
    echo "  ✓ HTTP to HTTPS redirect enabled"
    echo "  ✓ HSTS security header enabled"
    echo "  ✓ OCSP stapling enabled"
    echo "  ✓ Automatic renewal configured (runs twice daily)"
    echo ""
    echo -e "${YELLOW}Your site is now accessible at:${NC}"
    echo -e "  ${GREEN}https://${DOMAIN}${NC}"
    echo ""
    echo -e "${YELLOW}HTTP requests will automatically redirect to HTTPS${NC}"
    echo ""
    echo -e "${BLUE}Certificate Management:${NC}"
    echo ""
    echo "View certificate info:"
    echo -e "  ${BLUE}sudo certbot certificates -d ${DOMAIN}${NC}"
    echo ""
    echo "Manual renewal (not needed, auto-renews):"
    echo -e "  ${BLUE}sudo certbot renew${NC}"
    echo ""
    echo "Revoke certificate:"
    echo -e "  ${BLUE}sudo certbot revoke --cert-path /etc/letsencrypt/live/${DOMAIN}/cert.pem${NC}"
    echo ""
    echo -e "${GREEN}Certificates auto-renew 30 days before expiration!${NC}"
    echo ""
}

################################################################################
# Main Execution
################################################################################

print_status "Starting Let's Encrypt SSL setup for: $DOMAIN"
echo ""

install_certbot
generate_certificate
verify_setup

display_summary
