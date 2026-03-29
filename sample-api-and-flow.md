# Sample API & Application Flow

## Table of Contents

1. [Application Flow Diagrams](#application-flow-diagrams)
2. [Payment Service API](#payment-service-api)
3. [Order Service API](#order-service-api)
4. [Notification Service API](#notification-service-api)
5. [Kafka Event Schemas](#kafka-event-schemas)

---

## Application Flow Diagrams

### Flow 1: Happy Path — Create Order → Payment → Notification

```
┌──────────┐     ┌───────────────┐     ┌─────────────────┐     ┌──────────────┐     ┌──────────────────────┐
│  Client   │     │ Order Service │     │ Payment Service │     │ Payment GW   │     │ Notification Service │
└─────┬─────┘     └──────┬────────┘     └────────┬────────┘     └──────┬───────┘     └──────────┬───────────┘
      │                  │                       │                     │                        │
      │  POST /orders    │                       │                     │                        │
      │─────────────────>│                       │                     │                        │
      │                  │                       │                     │                        │
      │                  │  POST /payments       │                     │                        │
      │                  │──────────────────────>│                     │                        │
      │                  │                       │                     │                        │
      │                  │                       │  charge(request)    │                        │
      │                  │                       │────────────────────>│                        │
      │                  │                       │                     │                        │
      │                  │                       │  gatewayRefId       │                        │
      │                  │                       │<────────────────────│                        │
      │                  │                       │                     │                        │
      │                  │                       │──┐ Save Payment     │                        │
      │                  │                       │  │ (status=PENDING) │                        │
      │                  │                       │<─┘                  │                        │
      │                  │                       │                     │                        │
      │                  │                       │  Publish: payment-events                     │
      │                  │                       │  (CREATED)          │                        │
      │                  │                       │─────────────────────────────────────────────>│
      │                  │                       │                     │                        │
      │                  │  paymentId + redirect  │                     │                        │
      │                  │<──────────────────────│                     │                        │
      │                  │                       │                     │                        │
      │                  │──┐ Update Order        │                     │                        │
      │                  │  │ (AWAITING_PAYMENT)  │                     │                        │
      │                  │<─┘                    │                     │                        │
      │                  │                       │                     │                        │
      │                  │  Publish: order-events │                     │                        │
      │                  │  (CREATED)            │                     │                        │
      │                  │──────────────────────────────────────────────────────────────────────>│
      │                  │                       │                     │                        │
      │  orderNumber +   │                       │                     │                        │
      │  paymentRedirect │                       │                     │                        │
      │<─────────────────│                       │                     │                        │
      │                  │                       │                     │                        │
      │                  │                       │                     │                        │
      │    ═══════════════  USER PAYS VIA GATEWAY  ════════════════    │                        │
      │                  │                       │                     │                        │
      │                  │                       │  CALLBACK (success) │                        │
      │                  │                       │<────────────────────│                        │
      │                  │                       │                     │                        │
      │                  │                       │──┐ Idempotency:     │                        │
      │                  │                       │  │ check terminal   │                        │
      │                  │                       │  │ Save callback    │                        │
      │                  │                       │  │ Update → SUCCESS │                        │
      │                  │                       │<─┘                  │                        │
      │                  │                       │                     │                        │
      │                  │                       │  Publish: payment-events                     │
      │                  │                       │  (COMPLETED)        │                        │
      │                  │                       │─────────────────────────────────────────────>│
      │                  │                       │                     │                        │
      │                  │  Consume: payment-events                    │                        │
      │                  │  (COMPLETED)          │                     │                        │
      │                  │<────────────────────────────────────────────────────(from Kafka)     │
      │                  │                       │                     │                        │
      │                  │──┐ Update Order       │                     │                        │
      │                  │  │ (status=PAID)      │                     │                        │
      │                  │<─┘                    │                     │                        │
      │                  │                       │                     │                        │
      │                  │  Publish: order-events │                     │                        │
      │                  │  (PAID)               │                     │                        │
      │                  │──────────────────────────────────────────────────────────────────────>│
      │                  │                       │                     │                        │
      │                  │                       │                     │                        │──┐ Send email
      │                  │                       │                     │                        │  │ "Pembayaran
      │                  │                       │                     │                        │  │  berhasil"
      │                  │                       │                     │                        │<─┘
      │                  │                       │                     │                        │
```

### Flow 2: Duplicate Callback Handling (Idempotency)

```
┌──────────────┐     ┌─────────────────┐
│ Payment GW   │     │ Payment Service │
└──────┬───────┘     └────────┬────────┘
       │                      │
       │  CALLBACK #1         │
       │  (status=success)    │
       │─────────────────────>│
       │                      │──┐ 1. Find Payment by gatewayRefId
       │                      │  │ 2. Status = PENDING (not terminal)
       │                      │  │ 3. Acquire lock
       │                      │  │ 4. Update status → SUCCESS
       │                      │  │ 5. Save to PaymentCallback
       │                      │  │ 6. callbackReceivedCount = 1
       │                      │  │ 7. Publish COMPLETED event
       │                      │<─┘
       │                      │
       │  200 OK              │
       │<─────────────────────│
       │                      │
       │  CALLBACK #2         │
       │  (DUPLICATE!)        │
       │─────────────────────>│
       │                      │──┐ 1. Find Payment by gatewayRefId
       │                      │  │ 2. Status = SUCCESS (terminal!)
       │                      │  │ 3. Save to PaymentCallback (audit)
       │                      │  │ 4. callbackReceivedCount = 2
       │                      │  │ 5. SKIP processing
       │                      │  │ 6. DO NOT publish event
       │                      │  │ 7. Log: "Duplicate callback ignored"
       │                      │<─┘
       │                      │
       │  200 OK              │
       │<─────────────────────│
       │                      │
       │  CALLBACK #3         │
       │  (DUPLICATE!)        │
       │─────────────────────>│
       │                      │──┐ Same as #2
       │                      │  │ callbackReceivedCount = 3
       │                      │  │ SKIP + LOG
       │                      │<─┘
       │                      │
       │  200 OK              │
       │<─────────────────────│
```

### Flow 3: Idempotency — Duplicate Create Payment Request

```
┌───────────────┐     ┌─────────────────┐     ┌──────────────┐
│ Order Service │     │ Payment Service │     │ Payment GW   │
└──────┬────────┘     └────────┬────────┘     └──────┬───────┘
       │                       │                     │
       │  POST /payments       │                     │
       │  orderId="ORD-001"    │                     │
       │──────────────────────>│                     │
       │                       │──┐ Check: orderId   │
       │                       │  │ exists? → NO     │
       │                       │  │ Create Payment   │
       │                       │<─┘                  │
       │                       │  charge()           │
       │                       │────────────────────>│
       │                       │  gatewayRefId       │
       │                       │<────────────────────│
       │                       │                     │
       │  201 Created          │                     │
       │  paymentId=xxx        │                     │
       │<──────────────────────│                     │
       │                       │                     │
       │  POST /payments       │                     │
       │  orderId="ORD-001"    │                     │
       │  (RETRY/DUPLICATE)    │                     │
       │──────────────────────>│                     │
       │                       │──┐ Check: orderId   │
       │                       │  │ exists? → YES    │
       │                       │  │ Status=PENDING   │
       │                       │  │ Return existing  │
       │                       │  │ NO new charge!   │
       │                       │<─┘                  │
       │                       │                     │
       │  200 OK               │                     │
       │  paymentId=xxx (same) │                     │
       │<──────────────────────│                     │
```

### Flow 4: Service Interaction Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SYSTEM ARCHITECTURE                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌──────────┐     HTTP (sync)     ┌─────────────────┐                 │
│   │  Client   │───────────────────>│  Order Service   │                 │
│   │ (Browser/ │                    │  :8080           │                 │
│   │  Mobile)  │<───────────────────│                  │                 │
│   └──────────┘                     └────────┬─┬──────┘                 │
│                                        HTTP │ │ Kafka                   │
│                                     (sync)  │ │ (async)                 │
│                                             │ │                         │
│                                             v │                         │
│                                    ┌─────────────────┐                 │
│   ┌──────────────┐    callback     │ Payment Service │                 │
│   │ Payment GW   │───────────────>│  :8081           │                 │
│   │ (Dummy/Real) │<───────────────│                  │                 │
│   └──────────────┘    charge()     └────────┬────────┘                 │
│                                             │ Kafka                     │
│                                             │ (async)                   │
│                                             v                           │
│                              ┌──────────────────────────┐              │
│                              │   Apache Kafka            │              │
│                              │                           │              │
│                              │  Topics:                  │              │
│                              │  • payment-events         │              │
│                              │  • order-events           │              │
│                              └─────────┬────────────────┘              │
│                                        │ consume                        │
│                                        v                                │
│                              ┌──────────────────────────┐              │
│                              │ Notification Service     │              │
│                              │  :8082                   │              │
│                              │                          │              │
│                              │  Sends: Email/SMS/Push   │              │
│                              │  (dummy in dev)          │              │
│                              └──────────────────────────┘              │
│                                                                         │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐                               │
│   │ PG:5432 │  │ PG:5433 │  │ PG:5434 │    (Each service own DB)      │
│   │ payment │  │  order  │  │  notif  │                               │
│   │   _db   │  │   _db   │  │   _db   │                               │
│   └─────────┘  └─────────┘  └─────────┘                               │
└─────────────────────────────────────────────────────────────────────────┘
```

### Flow 5: Order State Machine

```
                    ┌─────────┐
                    │ CREATED │
                    └────┬────┘
                         │
              Payment Service called
              successfully
                         │
                         v
               ┌──────────────────┐
               │ AWAITING_PAYMENT │
               └────┬─────────┬──┘
                    │         │
         Payment    │         │  Payment
         SUCCESS    │         │  FAILED
                    │         │
                    v         v
              ┌──────┐   ┌────────┐
              │ PAID │   │ FAILED │
              └──────┘   └────────┘
                              
     ┌─────────┐  (from CREATED or AWAITING_PAYMENT only)
     │CANCELLED│<─── User cancels
     └─────────┘

     ┌─────────┐
     │ EXPIRED │<─── Scheduled job (future enhancement)
     └─────────┘
```

### Flow 6: Payment State Machine

```
              ┌─────────┐
              │ PENDING  │
              └────┬─────┘
                   │
        Gateway processing
                   │
                   v
            ┌────────────┐
            │ PROCESSING │  (optional, depends on gateway)
            └────┬───┬───┘
                 │   │
      Callback   │   │  Callback
      SUCCESS    │   │  FAILED
                 │   │
                 v   v
           ┌─────────┐  ┌────────┐
           │ SUCCESS  │  │ FAILED │
           └─────────┘  └────────┘

           ┌─────────┐
           │ EXPIRED  │ ← Scheduled cleanup
           └─────────┘

    Terminal states: SUCCESS, FAILED, EXPIRED
    (Duplicate callbacks on terminal states → logged & skipped)
```

---

## Payment Service API

**Base URL**: `http://localhost:8081/api/v1`

### POST /payments — Create Payment

**Request:**
```http
POST /api/v1/payments
Content-Type: application/json

{
  "orderId": "ORD-20260329143022-8472",
  "amount": 150000.00,
  "currency": "IDR",
  "description": "Payment for Order ORD-20260329143022-8472"
}
```

**Response (201 Created):**
```json
{
  "success": true,
  "message": "Payment created successfully",
  "data": {
    "paymentId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "orderId": "ORD-20260329143022-8472",
    "status": "PENDING",
    "amount": 150000.00,
    "currency": "IDR",
    "gatewayReferenceId": "GW-dummy-uuid-12345",
    "gatewayName": "DUMMY_GATEWAY",
    "redirectUrl": "https://dummy-gateway.example.com/pay/GW-dummy-uuid-12345"
  },
  "timestamp": "2026-03-29T14:30:22.123Z"
}
```

**Response (200 OK — Idempotent, payment already exists with PENDING):**
```json
{
  "success": true,
  "message": "Payment already exists for this order",
  "data": {
    "paymentId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "orderId": "ORD-20260329143022-8472",
    "status": "PENDING",
    "amount": 150000.00,
    "currency": "IDR",
    "gatewayReferenceId": "GW-dummy-uuid-12345",
    "gatewayName": "DUMMY_GATEWAY",
    "redirectUrl": "https://dummy-gateway.example.com/pay/GW-dummy-uuid-12345"
  },
  "timestamp": "2026-03-29T14:30:25.456Z"
}
```

**Response (409 Conflict — payment already SUCCESS):**
```json
{
  "success": false,
  "message": "Payment for order ORD-20260329143022-8472 already completed",
  "data": null,
  "timestamp": "2026-03-29T14:35:00.789Z"
}
```

**Response (400 Bad Request — validation error):**
```json
{
  "success": false,
  "message": "Validation failed",
  "data": {
    "errors": [
      {
        "field": "orderId",
        "message": "must not be blank"
      },
      {
        "field": "amount",
        "message": "must be greater than 0"
      }
    ]
  },
  "timestamp": "2026-03-29T14:30:22.123Z"
}
```

---

### GET /payments/{orderId} — Get Payment Status by Order ID

**Request:**
```http
GET /api/v1/payments/ORD-20260329143022-8472
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Payment found",
  "data": {
    "paymentId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "orderId": "ORD-20260329143022-8472",
    "status": "SUCCESS",
    "amount": 150000.00,
    "currency": "IDR",
    "gatewayName": "DUMMY_GATEWAY",
    "gatewayReferenceId": "GW-dummy-uuid-12345",
    "callbackReceivedCount": 2,
    "createdAt": "2026-03-29T14:30:22.123Z",
    "updatedAt": "2026-03-29T14:31:05.789Z"
  },
  "timestamp": "2026-03-29T14:32:00.000Z"
}
```

**Response (404 Not Found):**
```json
{
  "success": false,
  "message": "Payment not found for order: ORD-INVALID-123",
  "data": null,
  "timestamp": "2026-03-29T14:32:00.000Z"
}
```

---

### GET /payments/id/{paymentId} — Get Payment by Payment ID

**Request:**
```http
GET /api/v1/payments/id/a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

**Response (200 OK):** Same format as above.

---

### POST /callbacks/payment-gateway — Handle Gateway Callback

**Request (from Payment Gateway):**
```http
POST /api/v1/callbacks/payment-gateway
Content-Type: application/json
X-Gateway-Signature: sha256=abc123def456...

{
  "gateway_reference_id": "GW-dummy-uuid-12345",
  "status": "SUCCESS",
  "paid_amount": 150000.00,
  "paid_at": "2026-03-29T14:31:00.000Z",
  "metadata": {
    "channel": "bank_transfer",
    "bank": "BCA"
  }
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Callback processed",
  "data": null,
  "timestamp": "2026-03-29T14:31:01.234Z"
}
```

**Response (200 OK — duplicate callback, still returns success to gateway):**
```json
{
  "success": true,
  "message": "Callback already processed, skipping",
  "data": null,
  "timestamp": "2026-03-29T14:31:05.678Z"
}
```

---

## Order Service API

**Base URL**: `http://localhost:8080/api/v1`

### POST /orders — Create Order

**Request:**
```http
POST /api/v1/orders
Content-Type: application/json

{
  "customerName": "Budi Santoso",
  "customerEmail": "budi@example.com",
  "currency": "IDR",
  "notes": "Kirim sebelum jam 5 sore",
  "items": [
    {
      "productName": "Nasi Goreng Spesial",
      "quantity": 2,
      "unitPrice": 35000.00
    },
    {
      "productName": "Es Teh Manis",
      "quantity": 2,
      "unitPrice": 8000.00
    },
    {
      "productName": "Kerupuk",
      "quantity": 1,
      "unitPrice": 5000.00
    }
  ]
}
```

**Response (201 Created):**
```json
{
  "success": true,
  "message": "Order created successfully",
  "data": {
    "orderId": "f7e8d9c0-b1a2-3456-7890-abcdef123456",
    "orderNumber": "ORD-20260329143022-8472",
    "status": "AWAITING_PAYMENT",
    "totalAmount": 91000.00,
    "currency": "IDR",
    "paymentId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "paymentRedirectUrl": "https://dummy-gateway.example.com/pay/GW-dummy-uuid-12345",
    "createdAt": "2026-03-29T14:30:22.123Z"
  },
  "timestamp": "2026-03-29T14:30:22.456Z"
}
```

**Response (400 — validation error):**
```json
{
  "success": false,
  "message": "Validation failed",
  "data": {
    "errors": [
      {
        "field": "customerEmail",
        "message": "must be a well-formed email address"
      },
      {
        "field": "items",
        "message": "must not be empty"
      }
    ]
  },
  "timestamp": "2026-03-29T14:30:22.123Z"
}
```

---

### GET /orders/{orderNumber} — Get Order by Order Number

**Request:**
```http
GET /api/v1/orders/ORD-20260329143022-8472
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Order found",
  "data": {
    "orderId": "f7e8d9c0-b1a2-3456-7890-abcdef123456",
    "orderNumber": "ORD-20260329143022-8472",
    "customerName": "Budi Santoso",
    "customerEmail": "budi@example.com",
    "status": "PAID",
    "totalAmount": 91000.00,
    "currency": "IDR",
    "paymentId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "notes": "Kirim sebelum jam 5 sore",
    "items": [
      {
        "itemId": "11111111-2222-3333-4444-555555555555",
        "productName": "Nasi Goreng Spesial",
        "quantity": 2,
        "unitPrice": 35000.00,
        "subtotal": 70000.00
      },
      {
        "itemId": "22222222-3333-4444-5555-666666666666",
        "productName": "Es Teh Manis",
        "quantity": 2,
        "unitPrice": 8000.00,
        "subtotal": 16000.00
      },
      {
        "itemId": "33333333-4444-5555-6666-777777777777",
        "productName": "Kerupuk",
        "quantity": 1,
        "unitPrice": 5000.00,
        "subtotal": 5000.00
      }
    ],
    "createdAt": "2026-03-29T14:30:22.123Z",
    "updatedAt": "2026-03-29T14:31:05.789Z"
  },
  "timestamp": "2026-03-29T14:32:00.000Z"
}
```

---

### GET /orders/id/{orderId} — Get Order by UUID

**Request:**
```http
GET /api/v1/orders/id/f7e8d9c0-b1a2-3456-7890-abcdef123456
```

**Response (200 OK):** Same format as above.

---

### PATCH /orders/{orderNumber}/cancel — Cancel Order

**Request:**
```http
PATCH /api/v1/orders/ORD-20260329143022-8472/cancel
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Order cancelled successfully",
  "data": {
    "orderId": "f7e8d9c0-b1a2-3456-7890-abcdef123456",
    "orderNumber": "ORD-20260329143022-8472",
    "status": "CANCELLED",
    "totalAmount": 91000.00,
    "currency": "IDR",
    "updatedAt": "2026-03-29T14:33:00.000Z"
  },
  "timestamp": "2026-03-29T14:33:00.123Z"
}
```

**Response (409 Conflict — already PAID, cannot cancel):**
```json
{
  "success": false,
  "message": "Cannot cancel order with status PAID. Only CREATED or AWAITING_PAYMENT orders can be cancelled.",
  "data": null,
  "timestamp": "2026-03-29T14:33:00.123Z"
}
```

---

### GET /orders — List Orders (Paginated)

**Request:**
```http
GET /api/v1/orders?page=0&size=10&sort=createdAt,desc
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Orders retrieved",
  "data": {
    "content": [
      {
        "orderId": "f7e8d9c0-b1a2-3456-7890-abcdef123456",
        "orderNumber": "ORD-20260329143022-8472",
        "customerName": "Budi Santoso",
        "status": "PAID",
        "totalAmount": 91000.00,
        "currency": "IDR",
        "createdAt": "2026-03-29T14:30:22.123Z"
      }
    ],
    "page": 0,
    "size": 10,
    "totalElements": 1,
    "totalPages": 1,
    "last": true
  },
  "timestamp": "2026-03-29T14:35:00.000Z"
}
```

---

## Notification Service API

**Base URL**: `http://localhost:8082/api/v1`

> **Note**: Notification Service primarilyevent-driven (Kafka consumer). REST endpoints di bawah ini untuk admin/monitoring.

### GET /notifications/reference/{referenceId} — Get Notifications by Reference

**Request:**
```http
GET /api/v1/notifications/reference/ORD-20260329143022-8472
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Notifications found",
  "data": [
    {
      "id": "99999999-aaaa-bbbb-cccc-dddddddddddd",
      "referenceId": "ORD-20260329143022-8472",
      "referenceType": "ORDER",
      "recipientEmail": "budi@example.com",
      "type": "EMAIL",
      "trigger": "ORDER_CREATED",
      "subject": "Order Berhasil Dibuat - ORD-20260329143022-8472",
      "status": "SENT",
      "errorMessage": null,
      "retryCount": 0,
      "sentAt": "2026-03-29T14:30:23.000Z",
      "createdAt": "2026-03-29T14:30:22.800Z"
    },
    {
      "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      "referenceId": "ORD-20260329143022-8472",
      "referenceType": "PAYMENT",
      "recipientEmail": "budi@example.com",
      "type": "EMAIL",
      "trigger": "PAYMENT_SUCCESS",
      "subject": "Pembayaran Berhasil - ORD-20260329143022-8472",
      "status": "SENT",
      "errorMessage": null,
      "retryCount": 0,
      "sentAt": "2026-03-29T14:31:06.000Z",
      "createdAt": "2026-03-29T14:31:05.900Z"
    }
  ],
  "timestamp": "2026-03-29T14:35:00.000Z"
}
```

---

### GET /notifications/failed — List Failed Notifications

**Request:**
```http
GET /api/v1/notifications/failed?page=0&size=20
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Failed notifications retrieved",
  "data": {
    "content": [
      {
        "id": "bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
        "referenceId": "ORD-20260329150000-1234",
        "recipientEmail": "error@example.com",
        "type": "EMAIL",
        "trigger": "ORDER_CREATED",
        "status": "FAILED",
        "errorMessage": "SMTP connection timeout",
        "retryCount": 2,
        "createdAt": "2026-03-29T15:00:01.000Z"
      }
    ],
    "page": 0,
    "size": 20,
    "totalElements": 1,
    "totalPages": 1,
    "last": true
  },
  "timestamp": "2026-03-29T15:05:00.000Z"
}
```

---

### POST /notifications/{notificationId}/retry — Retry Failed Notification

**Request:**
```http
POST /api/v1/notifications/bbbbbbbb-cccc-dddd-eeee-ffffffffffff/retry
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Notification retried successfully",
  "data": {
    "id": "bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
    "referenceId": "ORD-20260329150000-1234",
    "status": "SENT",
    "retryCount": 3,
    "sentAt": "2026-03-29T15:06:00.000Z"
  },
  "timestamp": "2026-03-29T15:06:00.123Z"
}
```

---

## Kafka Event Schemas

### Topic: `payment-events`

**Published by**: Payment Service
**Consumed by**: Order Service, Notification Service

```json
{
  "eventId": "evt-a1b2c3d4-e5f6-7890",
  "eventType": "COMPLETED",
  "orderId": "ORD-20260329143022-8472",
  "paymentId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "status": "SUCCESS",
  "amount": 150000.00,
  "currency": "IDR",
  "gatewayName": "DUMMY_GATEWAY",
  "gatewayReferenceId": "GW-dummy-uuid-12345",
  "customerEmail": "budi@example.com",
  "timestamp": "2026-03-29T14:31:05.789Z"
}
```

**Event Types**: `CREATED`, `COMPLETED`, `FAILED`

---

### Topic: `order-events`

**Published by**: Order Service
**Consumed by**: Notification Service

```json
{
  "eventId": "evt-f7e8d9c0-b1a2-3456",
  "eventType": "CREATED",
  "orderNumber": "ORD-20260329143022-8472",
  "orderId": "f7e8d9c0-b1a2-3456-7890-abcdef123456",
  "status": "AWAITING_PAYMENT",
  "totalAmount": 91000.00,
  "currency": "IDR",
  "customerName": "Budi Santoso",
  "customerEmail": "budi@example.com",
  "timestamp": "2026-03-29T14:30:22.456Z"
}
```

**Event Types**: `CREATED`, `PAID`, `FAILED`, `CANCELLED`

---

## Port Mapping

| Service | Port | Database | DB Port |
|---|---|---|---|
| Order Service | 8080 | order_db | 5432 |
| Payment Service | 8081 | payment_db | 5432 |
| Notification Service | 8082 | notification_db | 5432 |
| Kafka | 9092 | — | — |
| Zookeeper | 2181 | — | — |

---

## Error Response Format (Consistent Across All Services)

```json
{
  "success": false,
  "message": "Human-readable error message",
  "data": null | { "errors": [...] },
  "timestamp": "2026-03-29T14:30:22.123Z"
}
```

| HTTP Status | Usage |
|---|---|
| 200 | Success (GET, idempotent POST) |
| 201 | Created (new resource) |
| 400 | Validation error, bad request |
| 404 | Resource not found |
| 409 | Conflict (duplicate, invalid state transition) |
| 500 | Internal server error |
| 502 | Upstream service unavailable (e.g., Payment GW down) |
