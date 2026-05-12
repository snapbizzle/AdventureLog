#!/bin/bash
set -euo pipefail

# =============================================================================
# AdventureLog Bare-Metal Installer Script
#
# This installer is for bare-metal Linux servers (Ubuntu/Debian) and sets up
# AdventureLog without Docker using system packages, systemd services, and Nginx.
# =============================================================================

APP_NAME="AdventureLog"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_DIR="/opt/adventurelog"

# Global configuration variables
declare -g REPO_DIR=""
declare -g DOMAIN_OR_IP=""
declare -g FRONTEND_PORT=""
declare -g BACKEND_PORT=""
declare -g DB_HOST=""
declare -g DB_PORT=""
declare -g DB_NAME=""
declare -g DB_USER=""
declare -g DB_PASSWORD=""
declare -g ADMIN_USERNAME=""
declare -g ADMIN_EMAIL=""
declare -g ADMIN_PASSWORD=""
declare -g SECRET_KEY=""
declare -g APP_USER="${SUDO_USER:-root}"
declare -g APP_GROUP="${SUDO_USER:-root}"
declare -g POSTGRES_MAJOR=""

# Color codes for beautiful output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_header() {
    echo -e "${PURPLE}$1${NC}"
}

print_banner() {
    cat << 'BANNER'
╔═════════════════════════════════════════════════════════════════════════╗
║                                                                         ║
║         A D V E N T U R E L O G   B A R E - M E T A L   S E T U P       ║
║                                                                         ║
║                    The Ultimate Travel Companion                        ║
║                                                                         ║
╚═════════════════════════════════════════════════════════════════════════╝
BANNER
}

print_header() {
    clear || true
    echo ""
    print_banner
    echo ""
    log_header "🚀 Starting bare-metal installation — $(date)"
    echo ""
}

on_error() {
    local line_number="$1"
    log_error "Installation failed on line ${line_number}."
    echo ""
    echo "Review the service logs for details:"
    echo "  • journalctl -u adventurelog-backend -f"
    echo "  • journalctl -u adventurelog-frontend -f"
}

trap 'on_error "$LINENO"' ERR

sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

require_non_empty() {
    local name="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        log_error "Required value '$name' is empty."
        exit 1
    fi
}

# =============================================================================
# Validation and system preparation
# =============================================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This installer must be run as root (or with sudo)."
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
        log_error "Unsupported OS: ${ID:-unknown}. This installer supports Ubuntu/Debian only."
        exit 1
    fi

    log_success "Detected supported OS: ${PRETTY_NAME:-$ID}"
}

install_missing_commands() {
    log_info "Checking required commands..."

    local required_commands=(git curl openssl python3 node npm psql)
    local install_packages=()

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                git) install_packages+=(git) ;;
                curl) install_packages+=(curl) ;;
                openssl) install_packages+=(openssl) ;;
                python3) install_packages+=(python3 python3-pip python3-venv) ;;
                node|npm) install_packages+=(nodejs npm) ;;
                psql) install_packages+=(postgresql-client) ;;
            esac
        fi
    done

    if [[ ${#install_packages[@]} -gt 0 ]]; then
        log_warning "Installing missing packages: ${install_packages[*]}"
        apt-get update
        apt-get install -y "${install_packages[@]}"
    fi

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command '$cmd' is still missing after installation."
            exit 1
        fi
    done

    log_success "All required pre-flight commands are available"
}

install_system_packages() {
    log_info "Installing system packages..."
    apt-get update

    if ! apt-get install -y \
      python3.11 python3.11-venv python3-pip \
      postgresql postgresql-contrib \
      gdal-bin libgdal-dev \
      memcached \
      nginx \
      nodejs npm \
      git curl openssl; then
        log_warning "python3.11 packages unavailable, retrying with distro default Python packages"
        apt-get install -y \
          python3 python3-venv python3-pip \
          postgresql postgresql-contrib \
          gdal-bin libgdal-dev \
          memcached \
          nginx \
          nodejs npm \
          git curl openssl
    fi

    if command -v pg_lsclusters >/dev/null 2>&1; then
        POSTGRES_MAJOR="$(pg_lsclusters --no-header 2>/dev/null | awk 'NR==1 {print $1}')"
    fi

    if [[ -z "$POSTGRES_MAJOR" ]] && command -v pg_config >/dev/null 2>&1; then
        local pg_version
        pg_version="$(pg_config --version | awk '{print $2}')"
        POSTGRES_MAJOR="${pg_version%%.*}"
    fi

    if [[ -z "$POSTGRES_MAJOR" ]]; then
        log_error "Unable to detect PostgreSQL version for PostGIS package installation."
        exit 1
    fi

    log_info "Installing PostGIS package for PostgreSQL ${POSTGRES_MAJOR}"
    apt-get install -y "postgresql-${POSTGRES_MAJOR}-postgis-3"
    log_success "System packages installed"
}

# =============================================================================
# Configuration prompts
# =============================================================================

prompt_configuration() {
    echo ""
    log_header "🛠️  Interactive Configuration"
    echo ""
    echo "Press Enter to use the default values shown in brackets."
    echo ""

    local default_repo_dir="$SCRIPT_DIR"
    local input_repo_dir
    if [[ -d "$SCRIPT_DIR/backend/server" && -d "$SCRIPT_DIR/frontend" ]]; then
        read -r -p "📁 AdventureLog directory [$default_repo_dir]: " input_repo_dir
        REPO_DIR="${input_repo_dir:-$default_repo_dir}"
    else
        default_repo_dir="$DEFAULT_REPO_DIR"
        read -r -p "📁 Install directory [$default_repo_dir]: " input_repo_dir
        REPO_DIR="${input_repo_dir:-$default_repo_dir}"
    fi

    read -r -p "🌐 Server domain or IP [127.0.0.1]: " DOMAIN_OR_IP
    DOMAIN_OR_IP="${DOMAIN_OR_IP:-127.0.0.1}"

    read -r -p "🎨 Frontend service port [3000]: " FRONTEND_PORT
    FRONTEND_PORT="${FRONTEND_PORT:-3000}"

    BACKEND_PORT="8000"
    log_info "Backend service port is fixed to 8000 for Gunicorn/systemd compatibility."

    read -r -p "🗄️  Database host [127.0.0.1]: " DB_HOST
    DB_HOST="${DB_HOST:-127.0.0.1}"

    read -r -p "🗄️  Database port [5432]: " DB_PORT
    DB_PORT="${DB_PORT:-5432}"

    read -r -p "🗄️  Database name [adventurelog]: " DB_NAME
    DB_NAME="${DB_NAME:-adventurelog}"

    read -r -p "🗄️  Database user [adventurelog]: " DB_USER
    DB_USER="${DB_USER:-adventurelog}"

    local generated_db_password
    generated_db_password="$(openssl rand -base64 24 | tr -d '\n')"
    read -r -p "🔐 Database password [auto-generated]: " DB_PASSWORD
    DB_PASSWORD="${DB_PASSWORD:-$generated_db_password}"

    read -r -p "👤 Admin username [admin]: " ADMIN_USERNAME
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

    read -r -p "📧 Admin email [admin@example.com]: " ADMIN_EMAIL
    ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"

    local generated_admin_password
    generated_admin_password="$(openssl rand -base64 24 | tr -d '\n')"
    read -r -p "🔐 Admin password [auto-generated]: " ADMIN_PASSWORD
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$generated_admin_password}"

    SECRET_KEY="$(openssl rand -base64 50 | tr -d '\n')"

    require_non_empty "REPO_DIR" "$REPO_DIR"
    require_non_empty "DOMAIN_OR_IP" "$DOMAIN_OR_IP"
    require_non_empty "FRONTEND_PORT" "$FRONTEND_PORT"
    require_non_empty "BACKEND_PORT" "$BACKEND_PORT"
    require_non_empty "DB_HOST" "$DB_HOST"
    require_non_empty "DB_PORT" "$DB_PORT"
    require_non_empty "DB_NAME" "$DB_NAME"
    require_non_empty "DB_USER" "$DB_USER"
    require_non_empty "DB_PASSWORD" "$DB_PASSWORD"
    require_non_empty "ADMIN_USERNAME" "$ADMIN_USERNAME"
    require_non_empty "ADMIN_EMAIL" "$ADMIN_EMAIL"
    require_non_empty "ADMIN_PASSWORD" "$ADMIN_PASSWORD"
    require_non_empty "SECRET_KEY" "$SECRET_KEY"

    if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ || ! "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
        log_error "Database name and user may only contain letters, numbers, and underscores."
        exit 1
    fi

    log_success "Configuration values validated"
}

prepare_repository() {
    if [[ -d "$REPO_DIR/backend/server" && -d "$REPO_DIR/frontend" ]]; then
        log_info "Using existing repository at $REPO_DIR"
        return
    fi

    log_info "Repository not found at $REPO_DIR, cloning AdventureLog"
    mkdir -p "$(dirname "$REPO_DIR")"

    if [[ -d "$REPO_DIR/.git" ]]; then
        git -C "$REPO_DIR" pull --ff-only
    else
        git clone https://github.com/snapbizzle/AdventureLog.git "$REPO_DIR"
    fi

    if [[ ! -d "$REPO_DIR/backend/server" || ! -d "$REPO_DIR/frontend" ]]; then
        log_error "Repository at $REPO_DIR is missing expected AdventureLog folders."
        exit 1
    fi

    log_success "Repository ready at $REPO_DIR"
}

write_environment_files() {
    log_info "Writing backend/server/.env"

    local backend_env="$REPO_DIR/backend/server/.env"
    local frontend_env="$REPO_DIR/frontend/.env"

    cp "$REPO_DIR/backend/server/.env.example" "$backend_env"
    cat > "$backend_env" <<EOF_BACKEND
PGHOST='$DB_HOST'
PGDATABASE='$DB_NAME'
PGUSER='$DB_USER'
PGPASSWORD='$DB_PASSWORD'
SECRET_KEY='$SECRET_KEY'
PUBLIC_URL='http://127.0.0.1:$BACKEND_PORT'
DEBUG=False
ENABLE_RATE_LIMITS=False
FRONTEND_URL='http://$DOMAIN_OR_IP'
EMAIL_BACKEND='console'
DJANGO_ADMIN_USERNAME='$ADMIN_USERNAME'
DJANGO_ADMIN_EMAIL='$ADMIN_EMAIL'
DJANGO_ADMIN_PASSWORD='$ADMIN_PASSWORD'
EOF_BACKEND

    log_info "Writing frontend/.env"
    cp "$REPO_DIR/frontend/.env.example" "$frontend_env"
    cat > "$frontend_env" <<EOF_FRONTEND
PUBLIC_SERVER_URL=http://127.0.0.1:8000
BODY_SIZE_LIMIT=Infinity
PUBLIC_UMAMI_SRC=
PUBLIC_UMAMI_WEBSITE_ID=
PORT=$FRONTEND_PORT
HOST=127.0.0.1
EOF_FRONTEND

    require_non_empty "backend .env PGHOST" "$(grep '^PGHOST=' "$backend_env" | cut -d= -f2-)"
    require_non_empty "backend .env SECRET_KEY" "$(grep '^SECRET_KEY=' "$backend_env" | cut -d= -f2-)"
    require_non_empty "frontend .env PUBLIC_SERVER_URL" "$(grep '^PUBLIC_SERVER_URL=' "$frontend_env" | cut -d= -f2-)"

    log_success "Environment files created"
}

# =============================================================================
# Database and backend setup
# =============================================================================

setup_postgresql_and_postgis() {
    log_info "Configuring PostgreSQL database and user"

    systemctl enable --now postgresql

    local escaped_db_user escaped_db_password escaped_db_name
    escaped_db_user="$(sql_escape "$DB_USER")"
    escaped_db_password="$(sql_escape "$DB_PASSWORD")"
    escaped_db_name="$(sql_escape "$DB_NAME")"

    sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF_SQL
DO
\$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${escaped_db_user}') THEN
        EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${escaped_db_user}', '${escaped_db_password}');
    END IF;
END
\$\$;
EOF_SQL

    sudo -u postgres psql -v ON_ERROR_STOP=1 -tc "SELECT 1 FROM pg_database WHERE datname='${escaped_db_name}'" | grep -q 1 || \
        sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"

    log_info "Creating PostGIS extension in database '$DB_NAME'"
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS postgis;"

    if sudo -u postgres psql -d "$DB_NAME" -tAc "SELECT extname FROM pg_extension WHERE extname='postgis';" | grep -q "postgis"; then
        log_success "PostGIS extension is active in database '$DB_NAME'"
    else
        log_error "PostGIS extension is not active in database '$DB_NAME'."
        echo "Run this manually to fix: sudo -u postgres psql -d $DB_NAME -c \"CREATE EXTENSION IF NOT EXISTS postgis;\""
        exit 1
    fi
}

setup_backend() {
    log_info "Setting up backend"

    local venv_dir="$REPO_DIR/backend/venv"
    local backend_dir="$REPO_DIR/backend/server"

    local python_cmd="python3.11"
    if ! command -v "$python_cmd" >/dev/null 2>&1; then
        python_cmd="python3"
    fi

    if [[ ! -d "$venv_dir" ]]; then
        "$python_cmd" -m venv "$venv_dir"
    fi

    local pip_bin="$venv_dir/bin/pip"
    local python_bin="$venv_dir/bin/python"
    local system_gdal_version
    local python_gdal_version

    "$pip_bin" install --upgrade pip wheel setuptools

    system_gdal_version="$(gdal-config --version)"
    require_non_empty "system GDAL version" "$system_gdal_version"

    log_info "Installing Python GDAL binding pinned to system GDAL version: $system_gdal_version"
    "$pip_bin" install "GDAL==$system_gdal_version"

    python_gdal_version="$(get_python_gdal_version "$python_bin")"

    if [[ "$python_gdal_version" != "$system_gdal_version" ]]; then
        log_error "GDAL version mismatch detected."
        echo "System GDAL: $system_gdal_version"
        echo "Python GDAL: $python_gdal_version"
        echo "Fix: $pip_bin install --force-reinstall GDAL==$system_gdal_version"
        exit 1
    fi

    log_success "GDAL versions match (system and Python: $system_gdal_version)"

    "$pip_bin" install -r "$backend_dir/requirements.txt"

    python_gdal_version="$(get_python_gdal_version "$python_bin")"
    if [[ "$python_gdal_version" != "$system_gdal_version" ]]; then
        log_error "GDAL version mismatch detected after requirements installation."
        echo "System GDAL: $system_gdal_version"
        echo "Python GDAL: $python_gdal_version"
        echo "Fix:"
        echo "  $pip_bin install --force-reinstall GDAL==$system_gdal_version"
        echo "  $pip_bin install -r $backend_dir/requirements.txt"
        exit 1
    fi

    (
        cd "$backend_dir"
        set -a
        # shellcheck disable=SC1090
        source .env
        set +a

        "$python_bin" manage.py migrate
        "$python_bin" manage.py collectstatic --noinput
        run_download_countries_with_guard "$python_bin"
        create_or_update_superuser "$python_bin"
    )

    log_success "Backend setup completed"
}

get_python_gdal_version() {
    local python_bin="$1"
    local version

    set +e
    version="$("$python_bin" <<'EOF_PY'
import importlib.metadata
import sys

try:
    print(importlib.metadata.version("GDAL"))
except importlib.metadata.PackageNotFoundError:
    sys.exit(42)
EOF_PY
)"
    local status=$?
    set -e

    if [[ "$status" -eq 42 ]]; then
        log_error "Python GDAL package is missing from the virtual environment."
        echo "Fix:"
        echo "  $python_bin -m pip install GDAL==$(gdal-config --version)"
        exit 1
    fi

    if [[ "$status" -ne 0 || -z "$version" ]]; then
        log_error "Unable to determine Python GDAL version."
        exit 1
    fi

    echo "$version"
}

run_download_countries_with_guard() {
    local python_bin="$1"
    local manual_command
    manual_command="cd $(pwd) && $python_bin manage.py download-countries"
    local mem_available_kb
    mem_available_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"

    if [[ -z "$mem_available_kb" ]]; then
        log_warning "Could not detect MemAvailable from /proc/meminfo; continuing without pre-check warning threshold."
    else
        local mem_available_mb
        mem_available_mb=$((mem_available_kb / 1024))
        log_info "Detected available memory: ${mem_available_mb} MB"

        if (( mem_available_mb < 1800 )); then
            echo ""
            log_warning "════════════════════════════════════════════════════════════════════════════"
            log_warning "LOW MEMORY WARNING"
            log_warning "MemAvailable is ${mem_available_mb} MB (< 1800 MB)."
            log_warning "The download-countries command may be OOM-killed on low-memory hosts."
            log_warning "If this happens, add swap or free memory, then run manually:"
            log_warning "  $manual_command"
            log_warning "Swap example:"
            log_warning "  sudo fallocate -l 2G /swapfile"
            log_warning "  sudo chmod 600 /swapfile"
            log_warning "  sudo mkswap /swapfile"
            log_warning "  sudo swapon /swapfile"
            log_warning "════════════════════════════════════════════════════════════════════════════"
            echo ""

            local continue_low_mem
            read -r -p "Continue download-countries now? [y/N]: " continue_low_mem
            if [[ ! "$continue_low_mem" =~ ^[Yy]$ ]]; then
                log_warning "Skipping download-countries by user choice due to low memory"
                return
            fi
        fi
    fi

    set +e
    "$python_bin" manage.py download-countries
    local download_exit_code=$?
    set -e

    if [[ "$download_exit_code" -eq 137 ]]; then
        log_error "The download-countries command was killed due to insufficient memory. Try freeing RAM or adding swap, then run this manually: $manual_command"
        return
    fi

    if [[ "$download_exit_code" -ne 0 ]]; then
        log_error "download-countries failed with exit code $download_exit_code"
        exit "$download_exit_code"
    fi

    log_success "download-countries completed"
}

create_or_update_superuser() {
    local python_bin="$1"

    "$python_bin" manage.py shell <<EOF_SUPERUSER
from django.contrib.auth import get_user_model

User = get_user_model()
username = "$ADMIN_USERNAME"
email = "$ADMIN_EMAIL"
password = "$ADMIN_PASSWORD"

user, created = User.objects.get_or_create(username=username, defaults={"email": email, "is_superuser": True, "is_staff": True})
if created:
    user.set_password(password)
    user.save()
    print("Created superuser:", username)
else:
    user.email = email
    user.is_superuser = True
    user.is_staff = True
    user.set_password(password)
    user.save()
    print("Updated existing superuser:", username)
EOF_SUPERUSER

    log_success "Admin user ensured"
}

# =============================================================================
# Frontend setup
# =============================================================================

setup_frontend() {
    log_info "Setting up frontend"
    (
        cd "$REPO_DIR/frontend"
        npm install
        npm run build
    )

    log_success "Frontend setup completed"
}

# =============================================================================
# Services and Nginx
# =============================================================================

create_systemd_services() {
    log_info "Creating systemd service files"

    cat > /etc/systemd/system/adventurelog-backend.service <<EOF_BACKEND_SERVICE
[Unit]
Description=AdventureLog Backend (Gunicorn)
After=network.target postgresql.service

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$REPO_DIR/backend/server
EnvironmentFile=$REPO_DIR/backend/server/.env
ExecStart=$REPO_DIR/backend/venv/bin/gunicorn main.wsgi:application --bind 127.0.0.1:8000 --workers 3
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_BACKEND_SERVICE

    cat > /etc/systemd/system/adventurelog-frontend.service <<EOF_FRONTEND_SERVICE
[Unit]
Description=AdventureLog Frontend (Node)
After=network.target adventurelog-backend.service

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$REPO_DIR/frontend
EnvironmentFile=$REPO_DIR/frontend/.env
ExecStart=/usr/bin/node $REPO_DIR/frontend/build/index.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_FRONTEND_SERVICE

    systemctl daemon-reload
    systemctl enable --now adventurelog-backend adventurelog-frontend
    log_success "Systemd services enabled and started"
}

configure_nginx() {
    log_info "Configuring Nginx"

    cat > /etc/nginx/sites-available/adventurelog <<EOF_NGINX
server {
    listen 80;
    server_name $DOMAIN_OR_IP;

    client_max_body_size 50M;

    location /static/ {
        alias $REPO_DIR/backend/server/static/;
    }

    location /media/ {
        alias $REPO_DIR/backend/server/media/;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /admin/ {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:$FRONTEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF_NGINX

    ln -sfn /etc/nginx/sites-available/adventurelog /etc/nginx/sites-enabled/adventurelog
    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx

    log_success "Nginx configured and reloaded"
}

print_final_summary() {
    echo ""
    log_header "🎉 Installation complete"
    echo ""
    echo -e "${BOLD}Access URLs:${NC}"
    echo "  • Frontend: http://$DOMAIN_OR_IP"
    echo "  • Backend API: http://$DOMAIN_OR_IP/api/"
    echo "  • Admin: http://$DOMAIN_OR_IP/admin/"
    echo ""
    echo -e "${BOLD}Admin credentials:${NC}"
    echo "  • Username: $ADMIN_USERNAME"
    echo "  • Email: $ADMIN_EMAIL"
    echo "  • Password: $ADMIN_PASSWORD"
    echo ""
    log_warning "Change default/admin credentials immediately after first login."
    echo ""
    echo -e "${BOLD}Service management:${NC}"
    echo "  • systemctl start adventurelog-backend"
    echo "  • systemctl stop adventurelog-backend"
    echo "  • systemctl restart adventurelog-backend"
    echo "  • systemctl start adventurelog-frontend"
    echo "  • systemctl restart adventurelog-frontend"
    echo ""
    echo -e "${BOLD}Logs:${NC}"
    echo "  • journalctl -u adventurelog-backend -f"
    echo "  • journalctl -u adventurelog-frontend -f"
}

main() {
    print_header
    check_root
    check_os
    install_missing_commands
    install_system_packages
    prompt_configuration
    prepare_repository
    write_environment_files
    setup_postgresql_and_postgis
    setup_backend
    setup_frontend
    create_systemd_services
    configure_nginx
    print_final_summary
}

main "$@"
