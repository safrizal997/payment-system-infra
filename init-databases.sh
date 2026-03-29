#!/bin/bash
# ============================================
# Script untuk membuat multiple database
# di satu PostgreSQL container.
# File ini di-mount ke /docker-entrypoint-initdb.d/
# dan dijalankan otomatis saat container pertama kali start.
# ============================================

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Payment Service database
    CREATE DATABASE payment_db;
    GRANT ALL PRIVILEGES ON DATABASE payment_db TO $POSTGRES_USER;

    -- Notification Service database
    CREATE DATABASE notification_db;
    GRANT ALL PRIVILEGES ON DATABASE notification_db TO $POSTGRES_USER;
EOSQL

echo "=== Databases created: order_db (default), payment_db, notification_db ==="
