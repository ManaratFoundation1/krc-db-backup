#!/bin/bash

#################################################################
# Validation Script - Check if everything is configured correctly
# Run this before installing to catch issues early
#################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}PostgreSQL Backup - Pre-Installation Check${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Function to print status
print_status() {
    local status=$1
    local message=$2
    
    if [ "$status" = "OK" ]; then
        echo -e "${GREEN}✓${NC} $message"
    elif [ "$status" = "ERROR" ]; then
        echo -e "${RED}✗${NC} $message"
        ((ERRORS++))
    elif [ "$status" = "WARN" ]; then
        echo -e "${YELLOW}⚠${NC} $message"
        ((WARNINGS++))
    fi
}

echo "Checking prerequisites..."
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_status "WARN" "Running as root - this is OK for validation"
fi

# Check for required commands
echo "1. Checking required commands..."
if command -v pg_dump &> /dev/null; then
    PG_VERSION=$(pg_dump --version | grep -oP '\d+' | head -1)
    print_status "OK" "pg_dump found (PostgreSQL $PG_VERSION)"
else
    print_status "ERROR" "pg_dump not found - PostgreSQL client tools required"
fi

if command -v aws &> /dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | cut -d' ' -f1)
    print_status "OK" "AWS CLI found ($AWS_VERSION)"
else
    print_status "ERROR" "AWS CLI not found - Install with: pip install awscli"
fi

if command -v gzip &> /dev/null; then
    print_status "OK" "gzip found"
else
    print_status "ERROR" "gzip not found"
fi

if command -v systemctl &> /dev/null; then
    print_status "OK" "systemd found"
else
    print_status "ERROR" "systemd not found - This script requires systemd"
fi

echo ""

# Check for postgres user
echo "2. Checking system user..."
if id -u postgres &>/dev/null; then
    print_status "OK" "postgres user exists"
else
    print_status "ERROR" "postgres user does not exist"
fi

echo ""

# Check .env file
echo "3. Checking configuration..."
if [ -f ".env" ]; then
    print_status "OK" ".env file exists"
    
    # Load and validate .env
    set -a
    source .env
    set +a
    
    # Check required variables
    REQUIRED_VARS=("PG_HOST" "PG_PORT" "PG_DATABASE" "PG_USER" "PGPASSWORD" "AWS_REGION" "S3_BUCKET")
    for var in "${REQUIRED_VARS[@]}"; do
        if [ -n "${!var}" ]; then
            print_status "OK" "$var is set"
        else
            print_status "ERROR" "$var is not set in .env"
        fi
    done
else
    print_status "ERROR" ".env file not found - Copy from .env.example"
fi

echo ""

# Test PostgreSQL connection
echo "4. Testing PostgreSQL connection..."
if [ -n "${PG_HOST}" ] && [ -n "${PG_USER}" ] && [ -n "${PGPASSWORD}" ] && [ -n "${PG_DATABASE}" ]; then
    if PGPASSWORD="${PGPASSWORD}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DATABASE}" -c "SELECT version();" &>/dev/null; then
        print_status "OK" "PostgreSQL connection successful"
    else
        print_status "ERROR" "Cannot connect to PostgreSQL - Check credentials"
    fi
else
    print_status "WARN" "Skipping PostgreSQL test - .env not configured"
fi

echo ""

# Test AWS credentials
echo "5. Testing AWS credentials..."
if aws sts get-caller-identity --region "${AWS_REGION:-us-east-1}" &>/dev/null; then
    AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    print_status "OK" "AWS credentials valid (Account: $AWS_ACCOUNT)"
    
    # Test S3 bucket access
    if [ -n "${S3_BUCKET}" ]; then
        if aws s3 ls "s3://${S3_BUCKET}" --region "${AWS_REGION}" &>/dev/null; then
            print_status "OK" "S3 bucket accessible: ${S3_BUCKET}"
        else
            print_status "ERROR" "Cannot access S3 bucket: ${S3_BUCKET}"
        fi
    fi
else
    print_status "ERROR" "AWS credentials not configured - Run: aws configure"
fi

echo ""

# Check disk space
echo "6. Checking disk space..."
TEMP_DIR="/tmp"
AVAILABLE_SPACE=$(df -BG "$TEMP_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$AVAILABLE_SPACE" -gt 10 ]; then
    print_status "OK" "Sufficient disk space in /tmp (${AVAILABLE_SPACE}GB available)"
else
    print_status "WARN" "Low disk space in /tmp (${AVAILABLE_SPACE}GB available)"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Validation Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed! Ready to install.${NC}"
    echo ""
    echo "Run: ${GREEN}sudo ./install.sh${NC}"
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠ $WARNINGS warning(s) found${NC}"
    echo "You can proceed but review warnings above"
    echo ""
    echo "Run: ${GREEN}sudo ./install.sh${NC}"
else
    echo -e "${RED}✗ $ERRORS error(s) found${NC}"
    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠ $WARNINGS warning(s) found${NC}"
    fi
    echo ""
    echo "Please fix the errors above before installing"
    exit 1
fi

echo ""
