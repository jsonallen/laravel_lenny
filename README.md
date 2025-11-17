# Laravel Lenny - Shell Scripts for Server Provisioning & Deployment

<p align="center">
  <img src="https://github.com/user-attachments/assets/3cf23e5d-cfaa-4e35-8ed7-4fec4cfeb0e9" alt="Laravel Lenny" width="128" style="border-radius: 16px;" />
</p>

Laravel Lenny is a simple set of bash scripts for configuring and hosting multiple Laravel applications on a single **Ubuntu 24.04 LTS** server. There are no confusing abstractions to deal with or monthly subscription costs. Just some basic shell scripts that get the job done.

**Requirements:**
- Ubuntu 24.04 LTS (fresh installation recommended)
- Root access
- SSH access
- Comfort with the CLI and navigating Linux

## Benefits

- **Easy to Read & Modify** - Shell scripts are straightforward and can be easily customized for your specific use case
- **No Third-Party Dependencies** - Uses only common Linux utilities that come pre-installed on most systems
- **No Monthly Costs** - No subscription fees or vendor lock-in
- **You Manage Your Own Security** - You don't give your SSH keys to anyone - full control over your server access
- **Full Transparency** - You own and understand every line of code running on your server

## Philosophy

Laravel Lenny uses a **three-script approach** to separate concerns:

1. **Server Provisioning** - One-time setup of the base Laravel environment
2. **Site Setup** - Add individual Laravel sites to the server
3. **Site Deployment** - Deploy code changes to any site

This allows you to run multiple Laravel sites on one server with proper isolation.

## What's Inside

- **`server-provision.sh`** - Provisions the base Laravel environment (PHP, MySQL, Nginx, etc.)
- **`site-setup.sh`** - Sets up an individual Laravel site (database, Nginx config, directories)
- **`site-letsencrypt-ssl.sh`** - Configures free SSL certificates from Let's Encrypt with auto-renewal
- **`site-deploy.sh`** - Triggers deployment from your local machine
- **`laravel-site-deploy.sh`** - Server-side deployment script (installed by provisioning)

## 📍 Where to Run Scripts

| Script | Run From | Purpose |
|--------|----------|---------|
| `server-provision.sh` | 🖥️ ON the server | One-time base environment setup |
| `site-setup.sh` | 🖥️ ON the server | Add each Laravel site |
| `site-letsencrypt-ssl.sh` | 🖥️ ON the server | Setup SSL certificates (requires DNS) |
| `site-deploy.sh` | 💻 FROM local machine | Deploy code changes (SSH's automatically) |

## Quick Start

### 1. Provision the Server (One-Time)

**🖥️ Run ON the server:**

```bash
# FROM YOUR LOCAL MACHINE: Copy script to server
scp server-provision.sh ubuntu@your-server.com:/tmp/

# SSH into the server
ssh ubuntu@your-server.com

# NOW ON THE SERVER: Run provisioning
sudo bash /tmp/server-provision.sh
```

**What it installs:**
- PHP 8.3 with extensions: mysql, curl, mbstring, xml, zip, bcmath, soap, intl, gd, redis, opcache
- Composer (latest)
- Node.js 22.x & npm
- MySQL 8.0
- Redis (latest from Ubuntu repos)
- Nginx (latest from Ubuntu repos)
- Supervisor (latest from Ubuntu repos)
- Laravel system user (`laravel`)
- GitHub SSH key (automatically generated for `laravel` user)
- Deployment script (`/usr/local/bin/laravel-site-deploy`)

**Important:** The script will display a public SSH key at the end that you need to add to GitHub manually.

### 2. Add Your First Site

**🖥️ Run ON the server:**

```bash
# FROM YOUR LOCAL MACHINE: Copy script to server
scp site-setup.sh root@your-server.com:/root/

# SSH into the server
ssh root@your-server.com

# NOW ON THE SERVER: Run site setup
sudo bash /root/site-setup.sh app.example.com
```

**What `site-setup.sh` creates:**
- Site directory: `/opt/app_example_com/`
- MySQL database: `app_example_com`
- MySQL user with random password
- Nginx server block
- Supervisor Horizon config
- Saves credentials to `/root/.app_example_com_mysql_credentials`

### 3. Add SSH Key to GitHub (One-Time)

The server provisioning script automatically generated an SSH key and displayed it at the end.

**💻 On GitHub (in your browser):**

1. Go to https://github.com/settings/keys
2. Click "New SSH key"
3. Paste the public key that was displayed after provisioning
4. Give it a title like "Production Server - [hostname]"
5. Click "Add SSH key"

**🖥️ If you need to view the key again:**

```bash
# SSH into the server and run:
sudo cat /home/laravel/.ssh/id_ed25519.pub
```

### 4. Initial Site Setup (One-Time)

**🖥️ Back ON the server:**

```bash
# Clone repository using SSH (you're still SSH'd into the server)
cd /opt/app_example_com
sudo -u laravel git clone git@github.com:you/repo.git .
# Note the '.' at the end - clones into the existing directory

# Install Composer dependencies
cd /opt/app_example_com
sudo -u laravel composer install --no-dev --optimize-autoloader

# Configure .env
sudo -u laravel cp /opt/app_example_com/.env.example /opt/app_example_com/.env
sudo -u laravel nano /opt/app_example_com/.env
```

Update these values in .env (credentials are in `/root/.app_example_com_mysql_credentials`):

```
APP_URL=https://app.example.com

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=app_example_com
DB_USERNAME=laravel_XXXX
DB_PASSWORD=your_generated_password
```

```bash
# Generate application key
sudo -u laravel php /opt/app_example_com/artisan key:generate

# Exit SSH session to return to local machine
exit
```

### 5. Deploy

**💻 Run FROM your local machine:**

```bash
# This runs on your laptop/workstation - it SSH's to the server for you
./site-deploy.sh app.example.com main
```

### 6. Setup SSL with Let's Encrypt (Optional but Recommended)

**⚠️ DNS REQUIREMENT:** Before running this step, ensure your domain's DNS A record points to your server's IP address!

**🖥️ Run ON the server:**

```bash
# Copy the SSL script to the server if not already there
scp site-letsencrypt-ssl.sh root@your-server:/root/

# SSH into the server
ssh root@your-server.com

# Setup free SSL certificate from Let's Encrypt
sudo bash /root/site-letsencrypt-ssl.sh app.example.com admin@example.com

# Exit
exit
```

This will:
- Install Certbot (if not present)
- Generate free SSL certificate from Let's Encrypt
- Configure Nginx for HTTPS
- Enable automatic HTTP → HTTPS redirect
- Setup automatic certificate renewal (renews every 60 days)

**Note:** Certificates are valid for 90 days and renew automatically!

**Re-running:** The script is idempotent and can be safely re-run if:
- Server IP address changes (update DNS first!)
- Certificate is expiring soon and you want to renew manually
- You need to update SSL configuration

## Adding More Sites

**🖥️ ON the server:**

```bash
# Copy site-setup.sh if you haven't already
# Then SSH in and run:
sudo bash /root/site-setup.sh staging.example.com

# Clone and configure (same as step 4 above)
cd /opt/staging_example_com
sudo -u laravel git clone git@github.com:you/repo.git .
sudo -u laravel composer install --no-dev --optimize-autoloader
sudo -u laravel cp /opt/staging_example_com/.env.example /opt/staging_example_com/.env
sudo -u laravel nano /opt/staging_example_com/.env
# (Update .env with DB credentials from /root/.staging_example_com_mysql_credentials)
sudo -u laravel php /opt/staging_example_com/artisan key:generate

# Exit when done
exit
```

**💻 Then FROM your local machine:**

```bash
./site-deploy.sh staging.example.com staging
```

Each site gets its own database, Nginx config, and Horizon supervisor, but shares PHP-FPM and the laravel user.

## Server Directory Structure

```
/opt/
├── app_example_com/       # Site 1
├── staging_example_com/   # Site 2
└── api_example_com/       # Site 3
```

## Deployment Process

1. Git pull
2. Composer install (production)
3. PHP-FPM reload
4. NPM build
5. Database migrations
6. Queue restart
7. Cache clearing
8. Filament optimization
9. Supervisor configuration reload (first deployment only)
10. Horizon restart

## Manual Operations

### Deploy on Server

```bash
laravel-site-deploy /opt/app_example_com main
```

### Manage Horizon

```bash
sudo supervisorctl status app_example_com-horizon
sudo supervisorctl restart app_example_com-horizon
```

### View Credentials

```bash
sudo cat /root/.app_example_com_mysql_credentials
```

## Troubleshooting

### Permission Issues

```bash
sudo chown -R laravel:laravel /opt/app_example_com
sudo chmod -R 775 /opt/app_example_com/storage
```

### Nginx Issues

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo tail -f /var/log/nginx/app.example.com-error.log
```

## Architecture

**Shared:** One laravel user, one PHP-FPM pool, MySQL/Redis servers, Nginx base

**Per-Site:** Directory, database, Nginx config, Supervisor config

## Why "Laravel Lenny"?

Because every good deployment system needs a name, and Lenny is a friendly companion for your Laravel deployment journey. Simple, approachable, and gets the job done!

## TODO

- **Zero Downtime Deployments** - Implement deployment strategy with no service interruption
- **PostgreSQL Support** - Add option to use PostgreSQL instead of MySQL
- **Test on Other Linux Variants** - Verify compatibility with other distributions beyond Ubuntu 24.04
