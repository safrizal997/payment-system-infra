# Payment System — Infrastructure

Docker Compose terpusat untuk menjalankan seluruh Payment System di local.

## Struktur Folder

```
projects/
├── payment-system-infra/       ← repo ini
│   ├── docker-compose.yml
│   ├── init-databases.sh
│   └── README.md
├── order-service/              ← repo Order Service (sibling folder)
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── pom.xml
│   └── src/
├── payment-service/            ← repo Payment Service (sibling folder)
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── pom.xml
│   └── src/
└── notification-service/       ← repo Notification Service (sibling folder)
    ├── Dockerfile
    ├── .dockerignore
    ├── pom.xml
    └── src/
```

> **Penting**: Ketiga repo service harus berada di **folder yang sama** (sibling) dengan repo infra ini, karena `docker-compose.yml` mereferensi `../order-service`, `../payment-service`, dan `../notification-service`.

## Quick Start

```bash
# 1. Clone semua repo ke folder yang sama
cd ~/projects
git clone <order-service-repo>
git clone <payment-service-repo>
git clone <notification-service-repo>
git clone <payment-system-infra-repo>

# 2. Jalankan semuanya
cd payment-system-infra
docker compose up -d

# 3. Tunggu semua service healthy
docker compose ps

# 4. Test
curl http://localhost:8080/api/v1/orders          # Order Service
curl http://localhost:8081/api/v1/payments         # Payment Service
curl http://localhost:8082/api/v1/notifications    # Notification Service
```

## Perintah Berguna

```bash
# Jalankan infrastructure saja (untuk development tanpa Docker)
docker compose up -d postgres kafka kafka-ui

# Rebuild setelah code berubah
docker compose up -d --build order-service payment-service notification-service

# Lihat logs service tertentu
docker compose logs -f payment-service

# Lihat logs semua service
docker compose logs -f order-service payment-service notification-service

# Restart satu service
docker compose restart order-service

# Shutdown semua
docker compose down

# Shutdown + hapus semua data (database, kafka)
docker compose down -v
```

## Akses

| Service | URL |
|---|---|
| Order Service | http://localhost:8080 |
| Order Swagger | http://localhost:8080/swagger-ui.html |
| Payment Service | http://localhost:8081 |
| Payment Swagger | http://localhost:8081/swagger-ui.html |
| Notification Service | http://localhost:8082 |
| Notification Swagger | http://localhost:8082/swagger-ui.html |
| Kafka UI | http://localhost:9090 |
| PostgreSQL | localhost:5432 (user: postgres, pass: postgres) |

## Databases

Satu container PostgreSQL dengan 3 database:

| Database | Service |
|---|---|
| order_db | Order Service |
| payment_db | Payment Service |
| notification_db | Notification Service |

Database dibuat otomatis oleh `init-databases.sh` saat container pertama kali start.
