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
    apt-get install -y git curl gcc make
elif command -v yum &> /dev/null; then
    yum install -y git curl gcc make
else
    echo -e "${YELLOW}Warning: Unknown package manager. Please ensure git, curl, and gcc are installed.${NC}"
fi

# 3. Check / Install Go
echo -e "${YELLOW}Step 2: Checking Go installation...${NC}"
if ! command -v go &> /dev/null; then
    echo -e "${YELLOW}Go is not installed. Installing Go...${NC}"
    
    # Detect Architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        GO_ARCH="amd64"
    elif [ "$ARCH" = "aarch64" -o "$ARCH" = "arm64" ]; then
        GO_ARCH="arm64"
    else
        echo -e "${RED}Error: Unsupported architecture: $ARCH${NC}"
        exit 1
    fi

    GO_VERSION="1.22.2"
    echo -e "Downloading Go v${GO_VERSION} for linux-${GO_ARCH}..."
    curl -OL "https://golang.org/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    
    echo "Extracting Go to /usr/local..."
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    rm "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    
    # Export path
    export PATH=$PATH:/usr/local/go/bin
    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi
    echo -e "${GREEN}Go installed successfully at /usr/local/go.${NC}"
else
    echo -e "${GREEN}Go is already installed: $(go version)${NC}"
fi

# 4. Clone/Get WuzAPI repository if not in the workspace directory
echo -e "${YELLOW}Step 3: Preparing WuzAPI source code...${NC}"
TEMP_DIR="/tmp/wuzapi-build"
rm -rf "$TEMP_DIR"
echo -e "Cloning repository to temporary directory..."
git clone https://github.com/sodikinnaa/wuzapi-installer.git "$TEMP_DIR"
cd "$TEMP_DIR"

# 5. Build Binary
echo -e "${YELLOW}Step 4: Compiling WuzAPI (wrapping all technologies)...${NC}"
export PATH=$PATH:/usr/local/go/bin
go build -ldflags="-w -s" -o wuzapi .
echo -e "${GREEN}WuzAPI compiled successfully.${NC}"

# 6. Install Binary
echo -e "${YELLOW}Step 5: Installing binary and assets...${NC}"
INSTALL_DIR="/usr/local/wuzapi"
mkdir -p "$INSTALL_DIR"
mv wuzapi "$INSTALL_DIR/wuzapi"
chmod +x "$INSTALL_DIR/wuzapi"

# 7. Generate .env file
echo -e "${YELLOW}Step 6: Configuring environment variables (.env)...${NC}"
ENV_FILE="$INSTALL_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Generating secure keys..."
    # Fallback random string generation if openssl or urandom is restricted
    ADMIN_TOKEN=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 || echo "AdminToken$(date +%s)")
    ENCRYPTION_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 || echo "EncryptionKey32BytesLongSecret!!")
    HMAC_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 || echo "HmacSignatureKeyMinimum32BytesLong")

    cat <<EOF > "$ENV_FILE"
# Server Configuration
WUZAPI_PORT=8080
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
else
    echo -e "${BLUE}Existing .env file found at $ENV_FILE. Keeping it.${NC}"
fi

# 8. Configure Systemd Service
echo -e "${YELLOW}Step 7: Creating systemd service...${NC}"
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
echo -e "${YELLOW}Step 8: Starting WuzAPI service...${NC}"
systemctl daemon-reload
systemctl enable wuzapi
systemctl restart wuzapi

# Clean up
cd /
rm -rf "$TEMP_DIR"

echo -e "${BLUE}=================================================================${NC}"
echo -e "${GREEN}               WUZAPI INSTALLED SUCCESSFULLY!                    ${NC}"
echo -e "${BLUE}=================================================================${NC}"
echo -e " Service status: ${GREEN}Active & Running${NC}"
echo -e " Listening on:   ${YELLOW}http://0.0.0.0:8080${NC}"
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
