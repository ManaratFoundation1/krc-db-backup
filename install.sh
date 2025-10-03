#!/bin/bash

#################################################################
# Installation Script for PostgreSQL Backup System
# Run this script as root or with sudo
#################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Installation paths
INSTALL_DIR="/opt/pg-backup"
SYSTEMD_DIR="/etc/systemd/system"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}PostgreSQL Backup System - Installation${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: Please run as root or with sudo${NC}"
    exit 1
fi

# Check if postgres user exists
if ! id -u postgres &>/dev/null; then
    echo -e "${RED}ERROR: postgres user does not exist${NC}"
    exit 1
fi

echo -e "${YELLOW}[1/7] Checking prerequisites...${NC}"

# Check for required commands
REQUIRED_CMDS=("pg_dump" "aws" "gzip" "systemctl")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}ERROR: Required command '$cmd' not found${NC}"
        echo "Please install it before continuing"
        exit 1
    fi
done

echo -e "${GREEN}✓ All prerequisites satisfied${NC}"

# Create installation directory
echo -e "${YELLOW}[2/7] Creating installation directory...${NC}"
mkdir -p "${INSTALL_DIR}"
echo -e "${GREEN}✓ Directory created: ${INSTALL_DIR}${NC}"

# Copy backup script
echo -e "${YELLOW}[3/7] Installing backup script...${NC}"
cp pg-backup.sh "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/pg-backup.sh"
chown postgres:postgres "${INSTALL_DIR}/pg-backup.sh"
echo -e "${GREEN}✓ Backup script installed${NC}"

# Setup .env file
echo -e "${YELLOW}[4/7] Setting up configuration...${NC}"
if [ -f "${INSTALL_DIR}/.env" ]; then
    echo -e "${YELLOW}⚠ .env file already exists, backing up to .env.backup${NC}"
    cp "${INSTALL_DIR}/.env" "${INSTALL_DIR}/.env.backup"
else
    cp .env.example "${INSTALL_DIR}/.env"
    echo -e "${YELLOW}⚠ Please edit ${INSTALL_DIR}/.env with your configuration${NC}"
fi
chown postgres:postgres "${INSTALL_DIR}/.env"
chmod 600 "${INSTALL_DIR}/.env"
echo -e "${GREEN}✓ Configuration file ready${NC}"

# Create backup and log directories
echo -e "${YELLOW}[5/7] Creating backup directories...${NC}"
mkdir -p /tmp/pg-backups
mkdir -p /var/log/pg-backup
chown postgres:postgres /tmp/pg-backups
chown postgres:postgres /var/log/pg-backup
chmod 750 /tmp/pg-backups
chmod 750 /var/log/pg-backup
echo -e "${GREEN}✓ Directories created${NC}"

# Install systemd service
echo -e "${YELLOW}[6/7] Installing systemd service...${NC}"
cp pg-backup.service "${SYSTEMD_DIR}/"
cp pg-backup.timer "${SYSTEMD_DIR}/"
systemctl daemon-reload
echo -e "${GREEN}✓ Systemd service installed${NC}"

# Enable and start timer
echo -e "${YELLOW}[7/7] Enabling systemd timer...${NC}"
systemctl enable pg-backup.timer
systemctl start pg-backup.timer
echo -e "${GREEN}✓ Timer enabled and started${NC}"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "1. Edit configuration: ${GREEN}${INSTALL_DIR}/.env${NC}"
echo -e "2. Test the backup manually: ${GREEN}sudo -u postgres ${INSTALL_DIR}/pg-backup.sh${NC}"
echo -e "3. Check timer status: ${GREEN}systemctl status pg-backup.timer${NC}"
echo -e "4. View logs: ${GREEN}journalctl -u pg-backup.service -f${NC}"
echo ""
echo -e "${YELLOW}Backup Schedule:${NC}"
echo -e "  - Daily at 07:00 UTC+3 (04:00 UTC)"
echo -e "  - Daily at 19:00 UTC+3 (16:00 UTC)"
echo ""
echo -e "${YELLOW}Management Commands:${NC}"
echo -e "  - View next backup time: ${GREEN}systemctl list-timers pg-backup.timer${NC}"
echo -e "  - Trigger manual backup: ${GREEN}systemctl start pg-backup.service${NC}"
echo -e "  - View service logs: ${GREEN}tail -f /var/log/pg-backup/backup_*.log${NC}"
echo -e "  - Stop timer: ${GREEN}systemctl stop pg-backup.timer${NC}"
echo -e "  - Restart timer: ${GREEN}systemctl restart pg-backup.timer${NC}"
echo ""
