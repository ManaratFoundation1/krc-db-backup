# PostgreSQL Backup System with S3 Storage

A production-ready, automated PostgreSQL backup solution with AWS S3 storage, intelligent rotation, and systemd integration.

## Features

- ✅ **Automated Backups**: Twice daily at 7 AM and 7 PM (UTC+3)
- ✅ **S3 Storage**: Secure cloud backup storage with lifecycle management
- ✅ **Smart Rotation**: Keeps last 2 backups, validates size before deletion
- ✅ **Size Validation**: Ensures backup integrity by comparing file sizes
- ✅ **Systemd Integration**: Auto-restart on failure, persistent scheduling
- ✅ **Comprehensive Logging**: Detailed logs with automatic cleanup
- ✅ **Compressed Backups**: Efficient storage with gzip compression
- ✅ **Security Hardened**: Resource limits and privilege restrictions

## Architecture

```
┌─────────────────┐
│   PostgreSQL    │
│   Database      │
└────────┬────────┘
         │
         │ pg_dump
         ▼
┌─────────────────┐
│  Backup Script  │
│  (pg-backup.sh) │
└────────┬────────┘
         │
         ├──► Create compressed backup
         ├──► Validate backup size
         ├──► Upload to S3
         ├──► Rotate old backups
         └──► Clean up local files
                    │
                    ▼
         ┌─────────────────────┐
         │   AWS S3 Bucket     │
         │  (Last 2 backups)   │
         └─────────────────────┘
```

## Prerequisites

- PostgreSQL 14+ installed
- AWS CLI installed and configured
- IAM role or credentials with S3 permissions
- systemd (Linux)
- Root access for installation

### Required AWS S3 Permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::your-backup-bucket/*",
        "arn:aws:s3:::your-backup-bucket"
      ]
    }
  ]
}
```

## Installation

### 1. Clone or Download

```bash
cd /home/devo/CascadeProjects/postgres-backup-system
```

### 2. Configure Environment Variables

Copy and edit the `.env` file:

```bash
cp .env.example .env
nano .env
```

**Required Configuration:**

```bash
# PostgreSQL Configuration
PG_HOST=localhost
PG_PORT=5432
PG_DATABASE=your_ecommerce_db
PG_USER=postgres
PGPASSWORD=your_secure_password

# AWS S3 Configuration
AWS_REGION=us-east-1
S3_BUCKET=your-backup-bucket
S3_PREFIX=postgres-backups

# Backup Configuration
BACKUP_LOCAL_DIR=/tmp/pg-backups
LOG_DIR=/var/log/pg-backup
TIMEZONE=UTC+3

# Size validation threshold (percentage)
MIN_SIZE_PERCENTAGE=50
```

### 3. Run Installation Script

```bash
chmod +x install.sh
sudo ./install.sh
```

This will:
- Install the backup script to `/opt/pg-backup`
- Create necessary directories
- Install systemd service and timer
- Enable automatic scheduling

### 4. Test the Backup

Run a manual backup to verify everything works:

```bash
sudo -u postgres /opt/pg-backup/pg-backup.sh
```

Check the logs:

```bash
tail -f /var/log/pg-backup/backup_*.log
```

Verify backup in S3:

```bash
aws s3 ls s3://your-backup-bucket/postgres-backups/
```

## Usage

### Check Backup Schedule

```bash
systemctl list-timers pg-backup.timer
```

### Manual Backup

```bash
sudo systemctl start pg-backup.service
```

### View Logs

**System logs:**
```bash
journalctl -u pg-backup.service -f
```

**Backup logs:**
```bash
tail -f /var/log/pg-backup/backup_*.log
```

### Service Management

**Status:**
```bash
systemctl status pg-backup.timer
systemctl status pg-backup.service
```

**Stop/Start:**
```bash
systemctl stop pg-backup.timer
systemctl start pg-backup.timer
```

**Restart:**
```bash
systemctl restart pg-backup.timer
```

**Disable:**
```bash
systemctl disable pg-backup.timer
```

## Backup Naming Convention

Backups follow the format: `HH:MM_DD-MM-YYYY.sql.gz`

Examples:
- `07:00_03-10-2025.sql.gz` (7 AM backup)
- `19:00_03-10-2025.sql.gz` (7 PM backup)

## How It Works

### 1. Backup Creation
- Uses `pg_dump` with custom format (`-F c`)
- Compresses with gzip level 9 for maximum compression
- Stores temporarily in `/tmp/pg-backups`

### 2. Size Validation
- Retrieves last backup size from S3
- Compares new backup with previous one
- Fails if new backup is less than 50% of last backup (configurable)
- Prevents corrupted or incomplete backups

### 3. S3 Upload
- Uploads to specified S3 bucket
- Uses `STANDARD_IA` storage class for cost optimization
- Adds metadata (timestamp, database name)

### 4. Rotation
- Lists all backups in S3
- Keeps last 2 backups
- Deletes older backups automatically

### 5. Cleanup
- Removes local backup file
- Cleans up logs older than 30 days

## Monitoring

### Check Next Backup Time

```bash
systemctl list-timers pg-backup.timer
```

### View Recent Backups in S3

```bash
aws s3 ls s3://your-backup-bucket/postgres-backups/ --recursive --human-readable
```

### Monitor Backup Success

```bash
journalctl -u pg-backup.service --since "1 day ago"
```

### Set Up Alerts (Optional)

Add email notifications on failure by editing `/etc/systemd/system/pg-backup.service`:

```ini
[Service]
OnFailure=email-notification@%n.service
```

## Troubleshooting

### Backup Script Fails

1. Check logs:
```bash
tail -f /var/log/pg-backup/backup_*.log
journalctl -u pg-backup.service -n 50
```

2. Verify PostgreSQL connection:
```bash
sudo -u postgres psql -h localhost -U postgres -d your_database -c "SELECT version();"
```

3. Test AWS credentials:
```bash
sudo -u postgres aws s3 ls s3://your-backup-bucket/
```

### Timer Not Running

```bash
systemctl status pg-backup.timer
systemctl restart pg-backup.timer
systemctl list-timers pg-backup.timer
```

### Permission Issues

Ensure postgres user has necessary permissions:
```bash
sudo chown -R postgres:postgres /opt/pg-backup
sudo chown -R postgres:postgres /var/log/pg-backup
sudo chown -R postgres:postgres /tmp/pg-backups
```

### Size Validation Failing

If legitimate backups are being rejected, adjust the threshold:
```bash
# Edit .env
MIN_SIZE_PERCENTAGE=30  # Lower threshold to 30%
```

## Restore Procedure

### 1. Download Backup from S3

```bash
aws s3 cp s3://your-backup-bucket/postgres-backups/07:00_03-10-2025.sql.gz /tmp/
```

### 2. Extract Backup

```bash
gunzip /tmp/07:00_03-10-2025.sql.gz
```

### 3. Restore Database

```bash
# Option 1: Restore to existing database (drops and recreates)
pg_restore -h localhost -U postgres -d your_database -c -v /tmp/07:00_03-10-2025.sql

# Option 2: Create new database and restore
createdb -h localhost -U postgres your_database_restored
pg_restore -h localhost -U postgres -d your_database_restored -v /tmp/07:00_03-10-2025.sql
```

## Security Considerations

- ✅ `.env` file has restricted permissions (600)
- ✅ Runs as postgres user with limited privileges
- ✅ Systemd security hardening enabled
- ✅ No credentials in logs
- ✅ S3 bucket should have encryption enabled
- ✅ Use IAM roles instead of access keys when possible

## Performance

- **CPU Limit**: 50% (configurable in service file)
- **Memory Limit**: 2GB (configurable in service file)
- **Compression**: Level 9 (maximum)
- **Network**: Uses AWS CLI multi-part upload for large files

## Cost Optimization

- Uses `STANDARD_IA` storage class (cheaper than STANDARD)
- Keeps only 2 backups (configurable)
- Compresses backups (typically 5-10x smaller)
- Automatic log cleanup after 30 days

## Customization

### Change Backup Schedule

Edit `/etc/systemd/system/pg-backup.timer`:

```ini
[Timer]
# Daily at 6 AM UTC+3 (03:00 UTC)
OnCalendar=*-*-* 03:00:00

# Daily at 6 PM UTC+3 (15:00 UTC)
OnCalendar=*-*-* 15:00:00
```

Then reload:
```bash
sudo systemctl daemon-reload
sudo systemctl restart pg-backup.timer
```

### Keep More Backups

Edit `/opt/pg-backup/pg-backup.sh` and change rotation logic:

```bash
# Change from 2 to desired number
if [ "$total_backups" -gt 5 ]; then
    local to_delete=$((total_backups - 5))
    ...
fi
```

### Backup Multiple Databases

Create separate timer/service for each database or modify script to loop through databases.

## Support

For issues or questions:
1. Check logs: `/var/log/pg-backup/`
2. Review systemd status: `journalctl -u pg-backup.service`
3. Verify AWS credentials and S3 permissions
4. Ensure PostgreSQL is running and accessible

## License

This backup system is provided as-is for production use.

## Changelog

- **v1.0.0** - Initial release
  - Twice-daily automated backups
  - S3 storage with rotation
  - Size validation
  - Systemd integration
  - Comprehensive logging
