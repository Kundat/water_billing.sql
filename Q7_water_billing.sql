-- =====================================================================
-- ICT371 Advanced Database  |  Question 7: Water Meter Readings and Billing
-- DBMS: PostgreSQL 14+   |  Scheduler: pg_cron extension
-- Tariff: first 10 units K5 each, units above 10 K8 each; 0 units = K0.
-- =====================================================================

-- (a) Database and seed data
DROP TABLE IF EXISTS receivable_snapshot CASCADE;
DROP TABLE IF EXISTS bills               CASCADE;
DROP TABLE IF EXISTS readings            CASCADE;
DROP TABLE IF EXISTS customers           CASCADE;

CREATE TABLE customers (
    customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id      INT  NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT ck_reading_month_start CHECK (reading_month = date_trunc('month', reading_month)::date),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (full_name) VALUES ('Mary Chileshe'), ('John Sikazwe'), ('Agnes Hamusonde');

-- (d) Trigger (installed before readings are loaded)
CREATE OR REPLACE FUNCTION trg_fn_reading_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;    -- a rejected row raises above, so it is never stored
END;
$$;

DROP TRIGGER IF EXISTS trg_reading_check ON readings;
CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_reading_check();

-- Six readings: zero, exactly 10 and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100, 100),   -- 1: 0 units
    (1, DATE '2026-10-01', 100, 110),   -- 2: 10 units
    (2, DATE '2026-09-01',  50,  65),   -- 3: 15 units
    (2, DATE '2026-10-01',  65,  90),   -- 4: 25 units
    (3, DATE '2026-09-01',   0,   7),   -- 5: 7 units
    (3, DATE '2026-10-01',   7,  47);   -- 6: 40 units

-- (b) Function
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must be non-negative)', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END;
$$;

SELECT fn_water_charge(0) AS c0, fn_water_charge(10) AS c10, fn_water_charge(15) AS c15;  -- 0.00, 50.00, 90.00

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev NUMERIC;
    v_curr NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END;
$$;

-- September bills are overdue, October bills are not yet due
CALL pr_generate_bill(1, CURRENT_DATE - 30);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(5, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE + 15);
CALL pr_generate_bill(4, CURRENT_DATE + 15);
CALL pr_generate_bill(6, CURRENT_DATE + 15);

-- Some payments: reading 5 paid in full (35.00), reading 3 part paid (40 of 90.00)
UPDATE bills SET amount_paid = charge WHERE reading_id = 5;
UPDATE bills SET amount_paid = 40     WHERE reading_id = 3;

SELECT * FROM bills ORDER BY bill_id;

-- Rule tests (expected failures)
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);     -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE);    -- unknown reading
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
-- Trigger: backwards reading is rejected and not stored
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, DATE '2026-11-01', 110, 105);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_still_6 FROM readings;

-- (e) View
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;   -- only John (50.00 outstanding)

-- (f) Index
-- Justification: overdue searches look at due_on among bills that are NOT fully
-- paid. A partial index on due_on limited to unpaid bills stays small (paid
-- bills are never stored in it) and supports the date range directly.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;   -- replace, never add
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- rerun: same single row
SELECT * FROM receivable_snapshot;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Daily at 00:30
SELECT cron.schedule(
    'water_refresh_receivables',
    '30 0 * * *',
    $job$CALL pr_refresh_receivables()$job$
);

SELECT jobid, jobname, schedule, command FROM cron.job;
