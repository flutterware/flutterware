-- Runs once, in the `shop` database, when the stack is first made.

-- The shop's orders, and the publication the sync service replicates. The lab
-- server makes both too, if missing, so a Postgres of your own works as well.
CREATE TABLE orders (
  id text PRIMARY KEY,
  customer_id text NOT NULL,
  item text NOT NULL,
  status text NOT NULL,
  placed_at timestamptz NOT NULL DEFAULT now(),
  shop_id text NOT NULL DEFAULT 'main'
);
CREATE PUBLICATION powersync FOR TABLE orders;

-- The sync service keeps its buckets in a database of its own.
CREATE DATABASE powersync_storage;
