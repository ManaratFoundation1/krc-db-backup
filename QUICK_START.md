# Quick Start Guide

## Installation (5 minutes)

### 1. Configure Environment
```bash
cd /home/devo/CascadeProjects/postgres-backup-system
cp .env.example .env
nano .env
```

Edit these values:
- `PG_DATABASE` - your database name
- `PG_USER` - your postgres user
- `PGPASSWORD` - your postgres password
- `S3_BUCKET` - your S3 bucket name
- `AWS_REGION` - your AWS region

### 2. Install
```bash
chmod +x install.sh
sudo ./install.sh
```

### 3. Test
```bash
sudo -u postgres /opt/pg-backup/pg-backup.sh
```

### 4. Verify
```bash
# Check S3
aws s3 ls s3://YOUR_BUCKET/postgres-backups/

# Check logs
tail -f /var/log/pg-backup/backup_*.log
```

## Common Commands

### Monitor
```bash
# Next backup time
systemctl list-timers pg-backup.timer

# Live logs
journalctl -u pg-backup.service -f

# Backup logs
tail -f /var/log/pg-backup/backup_*.log
```

### Manage
```bash
# Manual backup
sudo systemctl start pg-backup.service

# Stop scheduler
sudo systemctl stop pg-backup.timer

# Start scheduler
sudo systemctl start pg-backup.timer

# Restart scheduler
sudo systemctl restart pg-backup.timer
```

### Troubleshoot
```bash
# Service status
systemctl status pg-backup.timer
systemctl status pg-backup.service

# Recent logs
journalctl -u pg-backup.service -n 50

# Test PostgreSQL connection
sudo -u postgres psql -h localhost -U YOUR_USER -d YOUR_DB -c "SELECT version();"

# Test AWS access
sudo -u postgres aws s3 ls s3://YOUR_BUCKET/
```

## Restore Backup

```bash
# 1. Download
aws s3 cp s3://YOUR_BUCKET/postgres-backups/07:00_03-10-2025.sql.gz /tmp/

# 2. Extract
gunzip /tmp/07:00_03-10-2025.sql.gz

# 3. Restore
pg_restore -h localhost -U postgres -d YOUR_DB -c -v /tmp/07:00_03-10-2025.sql
```

## Backup Schedule

- **Morning**: 7:00 AM UTC+3 (4:00 AM UTC)
- **Evening**: 7:00 PM UTC+3 (4:00 PM UTC)

## File Locations

- **Script**: `/opt/pg-backup/pg-backup.sh`
- **Config**: `/opt/pg-backup/.env`
- **Logs**: `/var/log/pg-backup/`
- **Service**: `/etc/systemd/system/pg-backup.service`
- **Timer**: `/etc/systemd/system/pg-backup.timer`

## Need Help?

See full documentation: `README.md`
