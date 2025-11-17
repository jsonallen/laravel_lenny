#!/bin/bash

################################################################################
# Laravel Site Deployment Trigger Script
#
# This script runs LOCALLY and triggers deployment on remote server
#
# Usage: ./site-deploy.sh <domain> [branch]
# Example: ./site-deploy.sh app.example.com main
################################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# Validation
################################################################################

# Check for domain argument
if [ -z "$1" ]; then
    echo -e "${RED}Error: Domain argument required${NC}"
    echo "Usage: ./site-deploy.sh <domain> [branch]"
    echo ""
    echo "Examples:"
    echo "  ./site-deploy.sh app.example.com"
    echo "  ./site-deploy.sh staging.example.com staging"
    exit 1
fi

DOMAIN="$1"
BRANCH="${2:-main}"  # Default to main branch if not specified

# Convert domain to site directory name
SITE_NAME=$(echo "$DOMAIN" | tr '.' '_')
SITE_PATH="/opt/${SITE_NAME}"

################################################################################
# Deployment
################################################################################

# Display deployment information
echo ""
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}Laravel Site Deployment${NC}"
echo -e "${BLUE}=========================================${NC}"
echo -e "${YELLOW}Domain:${NC} $DOMAIN"
echo -e "${YELLOW}Site Path:${NC} $SITE_PATH"
echo -e "${YELLOW}Branch:${NC} $BRANCH"
echo -e "${BLUE}=========================================${NC}"
echo ""

# Ask for confirmation
read -p "Continue with deployment? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Deployment cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting deployment...${NC}"
echo ""

# SSH to server and run deployment script
# The -t flag allocates a pseudo-TTY for better output handling
# Assumes SSH config has Host configured or using laravel@domain
ssh -t "laravel@${DOMAIN}" "laravel-site-deploy ${SITE_PATH} ${BRANCH}"

# Capture exit code
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}Deployment completed successfully!${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo -e "${BLUE}Domain:${NC} $DOMAIN"
    echo -e "${BLUE}URL:${NC} https://$DOMAIN"
    echo ""
else
    echo -e "${RED}=========================================${NC}"
    echo -e "${RED}Deployment failed!${NC}"
    echo -e "${RED}=========================================${NC}"
    echo ""
    echo "Please check the error messages above."
    echo ""
fi

exit $EXIT_CODE
