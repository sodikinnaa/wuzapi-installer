#!/bin/bash

# WuzAPI Installer via curl
# Usage: curl -sSL https://raw.githubusercontent.com/sodikinnaa/wuzapi-installer/main/install.sh | bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}                    WUZAPI INSTALLER SCRIPT                      ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Detect System OS and Architecture
echo -e "${YELLOW}Step 1: Detecting system OS and architecture...${NC}"
OS_LOWER=$(uname -s | tr '[:upper:]' '[:lower:]')
OS="linux"
EXE_EXT=""

if [[ "$OS_LOWER" == *"linux"* ]]; then
    OS="linux"
elif [[ "$OS_LOWER" == *"darwin"* ]]; then
    OS="darwin"
elif [[ "$OS_LOWER" == *"mingw"* || "$OS_LOWER" == *"msys"* || "$OS_LOWER" == *"cygwin"* ]]; then
    OS="windows"
    EXE_EXT=".exe"
else
    echo -e "${YELLOW}Warning: Unknown OS ($OS_LOWER). Defaulting to Linux.${NC}"
    OS="linux"
fi

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    GO_ARCH="amd64"
elif [ "$ARCH" = "aarch64" -o "$ARCH" = "arm64" ]; then
    GO_ARCH="arm64"
else
    echo -e "${RED}Error: Unsupported architecture: $ARCH${NC}"
    exit 1
fi
echo -e "Detected platform: $OS-$GO_ARCH"

# Determine Installation Directory
INSTALL_DIR="/usr/local/wuzapi"
if [ "$OS" = "windows" ] || [ "$EUID" -ne 0 ]; then
    # Install in local directory if Windows or not running as root
    INSTALL_DIR="./wuzapi"
fi
mkdir -p "$INSTALL_DIR"

# Install basic dependencies (Linux only)
if [ "$OS" = "linux" ] && [ "$EUID" -eq 0 ]; then
    echo -e "${YELLOW}Step 2: Installing basic system dependencies...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -y < /dev/null
        apt-get install -y curl ca-certificates < /dev/null
    elif command -v yum &> /dev/null; then
        yum install -y curl ca-certificates < /dev/null
    fi
fi

# Fetch Version from GitHub API
echo -e "${YELLOW}Step 3: Determining latest release version...${NC}"
VERSION=""
# Try to get latest version from GitHub API
VERSION=$(curl -s https://api.github.com/repos/sodikinnaa/wuzapi-installer/releases/latest < /dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)

if [ -z "$VERSION" ]; then
    VERSION="v1.1.2"
    echo -e "Using default fallback version: $VERSION"
else
    echo -e "Latest release version: $VERSION"
fi

# Download Precompiled Binary
echo -e "${YELLOW}Step 4: Downloading precompiled binary from GitHub...${NC}"

# Stop systemd service if running (Linux only, systemd active)
if [ "$OS" = "linux" ] && [ "$EUID" -eq 0 ] && [ -d /run/systemd/system ]; then
    if systemctl list-units --full -all | grep -Fq 'wuzapi.service'; then
        echo -e "${YELLOW}Stopping WuzAPI service to allow update...${NC}"
        systemctl stop wuzapi || true
    fi
fi

BINARY_FILE="wuzapi-${VERSION}-${OS}-${GO_ARCH}"
if [ "$OS" = "windows" ]; then
    BINARY_FILE="${BINARY_FILE}.exe"
fi

BINARY_URL="https://github.com/sodikinnaa/wuzapi-installer/releases/download/${VERSION}/${BINARY_FILE}"
echo -e "Downloading from: $BINARY_URL"

# Download binary
curl -L -o "$INSTALL_DIR/wuzapi${EXE_EXT}" "$BINARY_URL" < /dev/null
chmod +x "$INSTALL_DIR/wuzapi${EXE_EXT}"
echo -e "${GREEN}Binary downloaded and installed successfully to $INSTALL_DIR/wuzapi${EXE_EXT}.${NC}"

# Configure environment variables (.env)
echo -e "${YELLOW}Step 5: Configuring environment variables (.env)...${NC}"
ENV_FILE="$INSTALL_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    WUZAPI_PORT=$(grep -E '^WUZAPI_PORT=' "$ENV_FILE" | cut -d= -f2 | tr -d ' \r\n')
    if [ -z "$WUZAPI_PORT" ]; then
        WUZAPI_PORT="8080"
    fi
    echo -e "Existing .env file found at $ENV_FILE. Configured port is $WUZAPI_PORT."
else
    echo "Finding a free port starting from 8080..."
    WUZAPI_PORT=8080
    while ss -lptn "sport = :$WUZAPI_PORT" 2>/dev/null | grep -q ":$WUZAPI_PORT " || grep -q "$(printf ':%04X' $WUZAPI_PORT)" /proc/net/tcp 2>/dev/null; do
        WUZAPI_PORT=$((WUZAPI_PORT + 1))
    done
    echo -e "Selected free port: $WUZAPI_PORT"

    echo "Generating secure keys..."
    ADMIN_TOKEN=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 || echo "AdminToken$(date +%s)")
    ENCRYPTION_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 || echo "EncryptionKey32BytesLongSecret!!")
    HMAC_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 || echo "HmacSignatureKeyMinimum32BytesLong")

    cat <<EOF > "$ENV_FILE"
# Server Configuration
WUZAPI_PORT=$WUZAPI_PORT
WUZAPI_ADDRESS=0.0.0.0

# WuzAPI Admin Token
WUZAPI_ADMIN_TOKEN=$ADMIN_TOKEN

# Encryption key for sensitive data (32 bytes)
WUZAPI_GLOBAL_ENCRYPTION_KEY=$ENCRYPTION_KEY

# Global HMAC Key for webhook signing
WUZAPI_GLOBAL_HMAC_KEY=$HMAC_KEY

# WuzAPI Session Configuration
SESSION_DEVICE_NAME=WuzAPI
TZ=UTC
EOF
    echo -e "${GREEN}Created new .env file at $ENV_FILE with auto-generated secure credentials.${NC}"
fi

# Change ownership to the user who ran sudo (so they can run the binary without sudo)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    chown -R "$SUDO_USER" "$INSTALL_DIR" || true
fi

# Port check warning
PORT_BUSY=false
if ss -lptn "sport = :$WUZAPI_PORT" 2>/dev/null | grep -q ":$WUZAPI_PORT " || grep -q "$(printf ':%04X' $WUZAPI_PORT)" /proc/net/tcp 2>/dev/null; then
    PORT_BUSY=true
    echo -e "${RED}Warning: Port $WUZAPI_PORT is already in use by another process!${NC}"
    echo -e "You might need to edit $ENV_FILE and change WUZAPI_PORT to a free port (e.g. 8086) then restart the service."
fi

# Configure Systemd Service (Linux only, running as root, systemd active)
if [ "$OS" = "linux" ] && [ "$EUID" -eq 0 ] && [ -d /run/systemd/system ]; then
    echo -e "${YELLOW}Step 6: Creating systemd service...${NC}"
    cat <<EOF > /etc/systemd/system/wuzapi.service
[Unit]
Description=Wuzapi Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

StartLimitIntervalSec=500
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=5s
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/wuzapi

[Install]
WantedBy=multi-user.target
EOF

    # Reload and Start Service
    echo -e "${YELLOW}Step 7: Starting WuzAPI service...${NC}"
    systemctl daemon-reload
    systemctl enable wuzapi
    systemctl restart wuzapi
else
    echo -e "${BLUE}[INFO] Systemd is not active in this environment (e.g. Cloud Shell/Docker). Skipping systemd service setup. You can run WuzAPI manually.${NC}"
fi

echo -e "${BLUE}=================================================================${NC}"
echo -e "${GREEN}               WUZAPI INSTALLED SUCCESSFULLY!                    ${NC}"
echo -e "${BLUE}=================================================================${NC}"
if [ "$OS" = "linux" ] && [ "$EUID" -eq 0 ] && [ -d /run/systemd/system ]; then
    if [ "$PORT_BUSY" = true ]; then
        echo -e " Service status: ${RED}Failed to Bind (Port Busy)${NC}"
    else
        echo -e " Service status: ${GREEN}Active & Running (Systemd)${NC}"
    fi
else
    if [ "$PORT_BUSY" = true ]; then
        echo -e " Port Status:    ${RED}Port $WUZAPI_PORT Busy${NC}"
    else
        echo -e " Port Status:    ${GREEN}Port $WUZAPI_PORT Available${NC}"
    fi
fi
echo -e " Listening on:   ${YELLOW}http://0.0.0.0:${WUZAPI_PORT}${NC}"
echo -e " Config folder:  ${YELLOW}$INSTALL_DIR${NC}"
echo ""
if [ "$OS" = "linux" ] && [ "$EUID" -eq 0 ] && [ -d /run/systemd/system ]; then
    echo -e " ${BLUE}How to manage WuzAPI Service:${NC}"
    echo -e "   Start:        ${YELLOW}systemctl start wuzapi${NC}"
    echo -e "   Stop:         ${YELLOW}systemctl stop wuzapi${NC}"
    echo -e "   Logs:         ${YELLOW}journalctl -u wuzapi -f${NC}"
else
    echo -e " ${BLUE}How to run WuzAPI manually:${NC}"
    if [ "$OS" = "windows" ]; then
        echo -e "   Run command:  ${YELLOW}cd $INSTALL_DIR && .\\wuzapi.exe${NC}"
    else
        echo -e "   Run command:  ${YELLOW}cd $INSTALL_DIR && ./wuzapi${NC}"
    fi
fi
echo ""
echo -e " ${BLUE}How to view database credentials and user tokens:${NC}"
if [ "$OS" = "windows" ]; then
    echo -e "   Run command:  ${GREEN}cd $INSTALL_DIR && .\\wuzapi.exe -show-credentials${NC}"
else
    echo -e "   Run command:  ${GREEN}cd $INSTALL_DIR && ./wuzapi -show-credentials${NC}"
fi
echo -e "${BLUE}=================================================================${NC}"
