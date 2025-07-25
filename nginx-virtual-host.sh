#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# =========================================================
# Bash Script: Create Nginx Virtual Host (Virtual Domain)
# =========================================================

# === Requirements:
# - Nginx
# - unzip (for WordPress)
# - wget (for WordPress)
# - mysql client (for interacting with MySQL / MariaDB)
# - PHP-FPM (e.g., php8.3-fpm)
# - /etc/nginx/snippets/self-signed.conf (for SSL certificate paths)
# - /etc/nginx/snippets/ssl-params.conf (for SSL/TLS parameters)
# - /etc/nginx/snippets/fastcgi-php.conf (for common PHP-FPM settings)
#
# === How to Run:
# This script must be executed with root privileges (sudo).
# sudo bash nginx-virtual-host.sh
# =========================================================

echo "======================================================="
echo "      Create Nginx Virtual Host (Virtual Domain)"
echo "======================================================="

# Function to validate domain name
# This regex checks for:
# - Overall structure (label.label.tld)
# - Valid characters (a-z, 0-9, hyphen) - STRICTLY LOWERCASE
# - No hyphens at the start/end of labels
# - Labels length (1 to 63 chars)
# - TLD length (at least 2 chars)
validate_domain() {
    local domain_name="$1"
    # Basic check for empty string
    if [[ -z "$domain_name" ]]; then
        return 1
    fi

    # Robust regex for domain validation (lowercase only)
    # Allows lowercase alphanumeric characters and hyphens, disallowing hyphens at start/end of labels.
    # Checks for at least one label and a TLD of at least 2 characters.
    local regex="^([a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$" # Changed a-zA-Z to a-z

    if [[ "$domain_name" =~ $regex ]]; then
        # Additional check for overall domain length (RFC max 253 characters)
        if [[ "${#domain_name}" -le 253 ]]; then
            return 0 # Valid
        fi
    fi
    return 1 # Invalid
}

# Function to validate PHP-FPM version input
validate_php_version() {
    local php_version="$1"
    # PHP version input MUST NOT be empty now.
    if [[ -z "$php_version" ]]; then
        return 1 # Invalid because it's empty
    fi
    # Specific common PHP versions regex:
    # Allows "php" (for generic php-fpm.sock)
    # Allows 5.6
    # Allows 7.0-7.4
    # Allows 8.0-8.4 (current common stable versions and likely future minor versions)
    local regex="^(php|5\.6|7\.[0-4]|8\.[0-4])$"

    if [[ "$php_version" =~ $regex ]]; then
        return 0 # Valid
    fi
    return 1 # Invalid
}


# === 1. Get Input from User: Domain Name ===
while true; do
    read -p "Enter your domain name (e.g., mysite.local or example.com - Use ONLY lowercase English characters, numbers, and hyphens): " domain # Updated prompt
    if [[ -z "$domain" ]]; then
        echo "Error: Domain name cannot be empty."
    elif ! validate_domain "$domain"; then
        echo "Error: Invalid domain name. Please use ONLY lowercase English letters (a-z), numbers (0-9), and hyphens (-)." # Updated error message
        echo "       Ensure it follows standard domain rules (e.g., no hyphens at start/end of parts, valid TLD)."
    else
        break # Valid domain, exit loop
    fi
done

# === 1.1. Get PHP-FPM Socket Version (and validate) ===
while true; do
    read -p "Enter your PHP-FPM socket version (e.g., 8.3, 7.4, 5.6, or 'php' for default): " php_fpm_version_input
    if validate_php_version "$php_fpm_version_input"; then
        break # Valid PHP version input, exit loop
    else
        echo "Error: Invalid or empty PHP-FPM version. Please enter 'php', '5.6', '7.0'-'7.4', or '8.0'-'8.4'."
    fi
done

php_fpm_socket="php-fpm.sock"
if [[ "$php_fpm_version_input" != "php" ]]; then
    php_fpm_socket="php${php_fpm_version_input}-fpm.sock"
fi

php_fpm_full_path="/var/run/php/${php_fpm_socket}"

echo "-------------------------------------------------------"
echo "✅ Using PHP-FPM socket: $php_fpm_full_path"

# === 2. Define Paths Based on Domain ===
root_dir="/var/www/$domain/public_html"
logs_dir="/var/www/$domain/logs"
nginx_conf="/etc/nginx/sites-available/$domain"

# === 3. Define Database Name (Replacing dots with underscores for MySQL compatibility) ===
db_name="${domain//./_}" # Replace dots with underscores for DB compatibility

echo "-------------------------------------------------------"
# echo "--- Starting configuration for domain: $domain ---"
echo "✅ Web files path: $root_dir"
echo "✅ Logs path: $logs_dir"
echo "✅ Suggested database name: $db_name"
echo "-------------------------------------------------------"

# === 4. Check for Existing Directories and Files (to prevent accidental overwrites) ===
if [ -d "$root_dir" ]; then
    echo "Warning: The web root directory '$root_dir' already exists."
    read -p "Do you want to continue? (Files might be overwritten) (y/n): " confirm_overwrite
    if [[ "$confirm_overwrite" != "y" && "$confirm_overwrite" != "Y" ]]; then
        echo "Operation cancelled. Exiting."
        exit 0 # Exit with success code, as user intentionally cancelled
    fi
fi

if [ -f "$nginx_conf" ]; then
    echo "Warning: Nginx configuration file '$nginx_conf' already exists. It will be overwritten."
fi

# === 5. Create Necessary Directories ===
echo "Creating necessary directories..."
mkdir -p "$root_dir" || { echo "Error: Failed to create $root_dir. Check permissions."; exit 1; }
mkdir -p "$logs_dir" || { echo "Error: Failed to create $logs_dir. Check permissions."; exit 1; }
echo "✅ Directories created successfully."

# === 6. Create Nginx Virtual Host Configuration File ===
echo "======================================================="
echo "Creating Nginx configuration file in $nginx_conf..."
cat > "$nginx_conf" <<EOF
#
# Virtual Host configuration for $domain
#
server {
    # Listen on HTTPS with HTTP/2 support
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    # Define domain names handled by this server block
    server_name $domain www.$domain;

    # Include SSL certificate and security parameters
    include snippets/self-signed.conf;
    include snippets/ssl-params.conf;

    # Enforce HTTPS with HSTS header (prevents downgrade attacks)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Document root
    root $root_dir;

    # Default index files
    index index.html index.php;

    # Access and error logs
    access_log /var/www/$domain/logs/$domain.access.log;
    error_log /var/www/$domain/logs/$domain.error.log;

    # Main request handler
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # Block access to sensitive files for security
    location ~* /(?:uploads/)?(\.ht|\.git|\.env|wp-config\.php) {
        deny all;
    }

    # PHP processing
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$php_fpm_full_path;

        # Ensure correct path is passed to PHP
        #fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        #include fastcgi_params;
    }

    # Allow large file uploads (up to 1000MB)
    client_max_body_size 1000M;
}

#
# Virtual Host for uploads subdomain
#
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    server_name uploads.$domain;

    include snippets/self-signed.conf;
    include snippets/ssl-params.conf;

    # HSTS enforcement
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Serve files from uploads directory
    root $root_dir/uploads;
    index index.html index.php;

    access_log /var/www/$domain/logs/uploads.$domain.access.log;
    error_log /var/www/$domain/logs/uploads.$domain.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # Block sensitive files
    location ~* /(?:uploads/)?(\.ht|\.git|\.env|wp-config\.php) {
        deny all;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$php_fpm_full_path;
        
        #fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        #include fastcgi_params;
    }

    client_max_body_size 1000M;
}

#
# Redirect all HTTP traffic to HTTPS for main domain
#
server {
    listen 80;
    listen [::]:80;

    server_name $domain www.$domain;

    # Permanent redirect to HTTPS
    return 301 https://\$host\$request_uri;

    access_log /var/log/nginx/redirect.to.https.access.log;
    error_log /var/log/nginx/redirect.to.https.error.log;
}

#
# Redirect all HTTP traffic to HTTPS for uploads subdomain
#
server {
    listen 80;
    listen [::]:80;

    server_name uploads.$domain;

    return 301 https://\$host\$request_uri;

    access_log /var/log/nginx/uploads.redirect.to.https.access.log;
    error_log /var/log/nginx/uploads.redirect.to.https.error.log;
}
EOF

echo "✅ Nginx configuration file created successfully."
echo "-------------------------------------------------------"

# === 7. Enable Nginx Site and Reload Nginx ===
echo "Enabling Nginx site (creating symlink)..."
if [ ! -L "/etc/nginx/sites-enabled/$domain" ]; then
    ln -s "$nginx_conf" /etc/nginx/sites-enabled/ || { echo "Error: Failed to create symlink."; exit 1; }
    echo "✅ Symlink created successfully in /etc/nginx/sites-enabled/."
else
    echo "Symlink for Nginx site already exists. Skipping."
fi

echo "-------------------------------------------------------"
echo "Testing Nginx configuration and reloading service..."
nginx -t && systemctl reload nginx || { echo "Error: Nginx failed to reload. Please check Nginx configuration manually."; exit 1; }
echo "Nginx tested and reloaded successfully. Current Nginx status (top 3 lines):"
systemctl status nginx | head -n 3
echo "======================================================="

# === 8. Add to /etc/hosts (for local domain access) ===
echo "Adding entry to /etc/hosts for local domain access..."
if ! grep -q "$domain" /etc/hosts; then
    echo "127.0.0.1 $domain www.$domain uploads.$domain" >> /etc/hosts
    echo "✅ Entry for '$domain' added to /etc/hosts."
else
    echo "Entry for '$domain' already exists in /etc/hosts. Skipping."
fi
echo "======================================================="

# === 9. Create MySQL Database ===
echo "--- MySQL Database Configuration ---"
echo "To create the database '$db_name', please enter the username and password of a MySQL user with sufficient privileges (e.g., root)."

read -p "MySQL Username (e.g., root): " mysql_admin_user
read -s -p "MySQL Password (hidden input): " mysql_admin_password
echo "" # For a new line after hidden password input
echo ""
echo "Attempting to create database: $db_name"

if echo "$mysql_admin_password" | mysql -u "$mysql_admin_user" -p"$mysql_admin_password" -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"; then
    echo "✅ Database \`$db_name\` created successfully."
else
    echo "Error: Database creation failed. Please check your MySQL username/password or ensure the user '$mysql_admin_user' has necessary privileges."
    exit 1
fi
echo "======================================================="

# === 10. Ask to Install WordPress and Proceed if Confirmed ===
read -p "Is this a WordPress site? Do you want to install it now? (y/n): " is_wp_choice

if [[ "$is_wp_choice" == "y" || "$is_wp_choice" == "Y" ]]; then
    echo ""
    echo "Downloading the latest WordPress version..."
    wget -P "$root_dir" https://wordpress.org/latest.zip || { echo "Error: WordPress download failed."; exit 1; }
    echo "Unzipping WordPress files..."
    unzip -q "$root_dir/latest.zip" -d "$root_dir" || { echo "Error: Unzipping WordPress failed."; exit 1; }
    rm -rf "$root_dir/wordpress/readme.html" "$root_dir/wordpress/license.txt" || { echo "Error: Cleaning up temporary WordPress files failed."; exit 1; }
    find "$root_dir/wordpress/wp-content/plugins/" -mindepth 1 ! -name 'index.php' -exec rm -rf {} + || { echo "Error: Cleaning up plugins failed."; exit 1; }
    find "$root_dir/wordpress/wp-content/themes/" -mindepth 1 ! -name 'index.php' -exec rm -rf {} + || { echo "Error: Cleaning up themes failed."; exit 1; }

    read -p "Do you want to install WordPress with the standard structure (default) or a custom structure? (s/c): " wp_structure_choice
    if [[ "$wp_structure_choice" == "s" ]]; then
        mv "$root_dir/wordpress/"* "$root_dir/" || { echo "Error: Moving WordPress files failed."; exit 1; }
        rm -rf "$root_dir/wordpress" "$root_dir/latest.zip" || { echo "Error: Cleaning up temporary WordPress files failed."; exit 1; }
    else
        mkdir -p "$root_dir/config" "$root_dir/core" "$root_dir/plugins" "$root_dir/public" "$root_dir/template" "$root_dir/uploads" "$root_dir/languages" || {
            echo "Error: Failed to create required directories."; exit 1;
        }

        mv "$root_dir/wordpress/wp-content/plugins/"* "$root_dir/plugins" || { echo "Error: Moving plugins failed."; exit 1; }
        rm -rf "$root_dir/wordpress/wp-content/plugins"

        mv "$root_dir/wordpress/wp-content/"* "$root_dir/public" || { echo "Error: Moving public content failed."; exit 1; }
        rm -rf "$root_dir/wordpress/wp-content"

        mv "$root_dir/wordpress/"* "$root_dir/core" || { echo "Error: Moving core files failed."; exit 1; }
        mv "$root_dir/core/index.php" "$root_dir/" || { echo "Error: Moving index.php from core failed."; exit 1; }
        # Copy index.php to required folders
        for dir in uploads config template core; do
            cp -i "$root_dir/public/index.php" "$root_dir/$dir" || { echo "Error: Copying index.php to $dir failed."; exit 1; }
        done

        rm -rf "$root_dir/wordpress" "$root_dir/latest.zip" || { echo "Error: Cleaning up temporary WordPress files failed."; exit 1; }

        sed -i '17s|.*|require __DIR__ . '\''/core/wp-blog-header.php'\'';|' "$root_dir/index.php" || { echo "Error: Replacing line 17 in index.php failed."; exit 1; }

        touch "$root_dir/config/theme-path.php" "$root_dir/config/upload-path.php" || { echo "Failed to create MU-Plugins file."; exit 1; }
    fi

    echo "WordPress installed successfully in $root_dir."

    echo "Setting file permissions for WordPress (for security and proper functioning)..."
    chown -R www-data:www-data "$root_dir" "$logs_dir" || { echo "Error: Setting file ownership failed."; exit 1; }
    # find "$root_dir" -type d -exec chmod 755 {} \; || { echo "Error: Setting directory permissions failed."; exit 1; }
    # find "$root_dir" -type f -exec chmod 644 {} \; || { echo "Error: Setting file permissions failed."; exit 1; }
    
    echo "WordPress permissions set."
else
    echo "WordPress installation skipped."
fi

echo ""
echo "======================================================="
echo "   ✅ Virtual host for $domain successfully set up."
echo "======================================================="
# echo "You can access your website by visiting https://$domain in your browser."
# echo "If you installed WordPress, you will need to manually create and configure"
# echo "your 'wp-config.php' file in '$root_dir' with your database details."
# echo "Go to https://$domain/wp-admin/install.php to complete the WordPress setup."
# echo "Remember to ensure your Nginx snippets for SSL and PHP-FPM exist and are correctly configured."
# echo "Place your website files in '$root_dir'."
# echo "======================================================="
# =============================================================
# define('WP_HOME', 'https://wordpress.test');
# define('WP_SITEURL', WP_HOME . '/core');
# define('WP_CONTENT_DIR', dirname(__DIR__) . '/public');
# define('WP_CONTENT_URL', WP_HOME . '/public');
# define('WP_PLUGIN_DIR', dirname(__DIR__) . '/plugins');
# define('WP_PLUGIN_URL', WP_HOME . '/plugins');
# define('WPMU_PLUGIN_DIR', dirname(__DIR__) . '/config');
# define('WPMU_PLUGIN_URL', WP_HOME . '/config');
# define( 'WP_LANG_DIR', dirname(__DIR__) . '/languages' );

# =============================================================
# <?php
# /**
#  * Plugin Name: Set Custom Theme Path
#  */

# register_theme_directory(dirname(__DIR__) . '/template');
# add_filter('theme_root', function () {
#     return dirname(__DIR__) . '/template';
# });
# add_filter('theme_root_uri', function () {
#     return home_url('/template');
# }, 10, 1);

# =============================================================
# <?php
# /**
#  * Plugin Name: Set Upload Settings Once
#  */

# add_action('init', function () {
#     if (!get_option('upload_path')) {
#         update_option('upload_path', '/var/www/wordpress.test/public_html/uploads');
#     }

#     if (!get_option('upload_url_path')) {
#         update_option('upload_url_path', 'https://uploads.wordpress.test');
#     }
# });

# =============================================================