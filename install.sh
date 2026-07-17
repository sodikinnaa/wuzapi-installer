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

# 1. Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (or with sudo).${NC}"
    exit 1
fi

# 2. Install basic dependencies
echo -e "${YELLOW}Step 1: Installing basic system dependencies...${NC}"
if command -v apt-get &> /dev/null; then
    apt-get update -y
    apt-get install -y curl ca-certificates
elif command -v yum &> /dev/null; then
    yum install -y curl ca-certificates
else
    echo -e "${YELLOW}Warning: Please ensure curl and ca-certificates are installed.${NC}"
fi

# 3. Detect Architecture and OS
echo -e "${YELLOW}Step 2: Detecting system architecture...${NC}"
OS="linux" # Currently we only support linux via this installer script since it sets up systemd
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

# 4. Fetch Version from GitHub API
echo -e "${YELLOW}Step 3: Determining latest release version...${NC}"
# Try to get latest version from GitHub API
VERSION=$(curl -s https://api.github.com/repos/sodikinnaa/wuzapi-installer/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)

if [ -z "$VERSION" ]; then
    VERSION="v1.0.8"
    echo -e "Using default fallback version: $VERSION"
else
    echo -e "Latest release version: $VERSION"
fi

# 5. Download Precompiled Binary
echo -e "${YELLOW}Step 4: Downloading precompiled binary from GitHub...${NC}"
INSTALL_DIR="/usr/local/wuzapi"
mkdir -p "$INSTALL_DIR"

# Stop service if running to avoid "Text file busy" error during binary overwrite
if systemctl list-units --full -all | grep -Fq 'wuzapi.service'; then
    echo -e "${YELLOW}Stopping WuzAPI service to allow update...${NC}"
    systemctl stop wuzapi || true
fi

BINARY_URL="https://github.com/sodikinnaa/wuzapi-installer/releases/download/${VERSION}/wuzapi-${VERSION}-${OS}-${GO_ARCH}"
echo -e "Downloading from: $BINARY_URL"

# Download binary
curl -L -o "$INSTALL_DIR/wuzapi" "$BINARY_URL"
chmod +x "$INSTALL_DIR/wuzapi"
echo -e "${GREEN}Binary downloaded and installed successfully to $INSTALL_DIR/wuzapi.${NC}"

# 6. Generate .env file
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

# Port check warning
PORT_BUSY=false
if ss -lptn "sport = :$WUZAPI_PORT" 2>/dev/null | grep -q ":$WUZAPI_PORT " || grep -q "$(printf ':%04X' $WUZAPI_PORT)" /proc/net/tcp 2>/dev/null; then
    PORT_BUSY=true
    echo -e "${RED}Warning: Port $WUZAPI_PORT is already in use by another process!${NC}"
    echo -e "You might need to edit $ENV_FILE and change WUZAPI_PORT to a free port (e.g. 8086) then restart the service."
fi

# 7. Configure Systemd Service
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

echo -e "${BLUE}=================================================================${NC}"
echo -e "${GREEN}               WUZAPI INSTALLED SUCCESSFULLY!                    ${NC}"
echo -e "${BLUE}=================================================================${NC}"
if [ "$PORT_BUSY" = true ]; then
    echo -e " Service status: ${RED}Failed to Bind (Port Busy)${NC}"
else
    echo -e " Service status: ${GREEN}Active & Running${NC}"
fi
echo -e " Listening on:   ${YELLOW}http://0.0.0.0:${WUZAPI_PORT}${NC}"
echo -e " Config folder:  ${YELLOW}$INSTALL_DIR${NC}"
echo ""
echo -e " ${BLUE}How to manage WuzAPI Service:${NC}"
echo -e "   Start:        ${YELLOW}systemctl start wuzapi${NC}"
echo -e "   Stop:         ${YELLOW}systemctl stop wuzapi${NC}"
echo -e "   Logs:         ${YELLOW}journalctl -u wuzapi -f${NC}"
echo ""
echo -e " ${BLUE}How to view database credentials and user tokens:${NC}"
echo -e "   Run command:  ${GREEN}$INSTALL_DIR/wuzapi -show-credentials${NC}"
echo -e "${BLUE}=================================================================${NC}"
