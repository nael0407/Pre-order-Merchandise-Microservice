CREATE DATABASE IF NOT EXISTS merch_preorder
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE merch_preorder;

CREATE TABLE IF NOT EXISTS orders (
  order_id      VARCHAR(64)  NOT NULL,
  batch_id      VARCHAR(64)  NOT NULL,
  customer_name VARCHAR(100) NOT NULL,
  contact       VARCHAR(32)  NOT NULL,
  size          ENUM('S', 'M', 'L', 'XL') NOT NULL,
  qty           INT          NOT NULL,
  status        ENUM('pending', 'paid', 'picked-up', 'cancelled', 'expired') NOT NULL DEFAULT 'pending',
  pay_deadline  DATETIME     NULL,
  created_at    DATETIME     NOT NULL,
  updated_at    DATETIME     NOT NULL,
  PRIMARY KEY (order_id),
  INDEX idx_orders_batch_contact_status (batch_id, contact, status),
  INDEX idx_orders_status_deadline (status, pay_deadline)
);

