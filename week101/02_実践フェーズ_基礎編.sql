-- ============================================================
-- Frosty Friday Week 101 - 実践フェーズ（基礎編）
-- テーマ: 条件付き INSERT（マルチテーブル）（海賊データ）
-- URL: https://frostyfriday.org/blog/2024/07/12/week-101-easy/
-- 実行ロール: FROSTY_FRIDAY_ROLE
-- ============================================================

USE ROLE FROSTY_FRIDAY_ROLE;
USE DATABASE frosty_friday;
USE SCHEMA week101;

-- ------------------------------------------------------------
-- 振り分け条件の整理
-- ------------------------------------------------------------
-- 条件A: booty_amount > 700 → t1 のみ
-- 条件B: rank = 'First Mate' → t2 のみ
-- 条件C: booty_amount < 100 → t1 と t2 の両方
-- それ以外 (ELSE) → t2 のみ
--
-- 「両方に入れる」ケース（条件C）があるため INSERT ALL を使用。
-- INSERT FIRST だと最初に一致した条件しか実行されず両方に入らない
-- （応用編 SECTION 2 で実証する）。
-- ------------------------------------------------------------


-- ============================================================
-- STEP 1: 実行前のターゲットテーブル確認
-- ============================================================

-- 1-1. t1 / t2 を初期化（再実行時の重複防止）
TRUNCATE TABLE t1;
TRUNCATE TABLE t2;

-- 1-2. ターゲットが空であることを確認
-- 想定: t1=0 / t2=0
SELECT 't1' AS table_name, COUNT(*) AS row_count FROM t1
UNION ALL
SELECT 't2', COUNT(*) FROM t2;


-- ============================================================
-- STEP 2: 実行前の振り分け想定の可視化
-- ============================================================

-- INSERT ALL 実行後の t1 / t2 が、この to_t1 / to_t2 の Y と一致するはず。
-- お題ルールを CASE で先に視覚化することで、実行結果を予測してから INSERT する。
-- 想定: to_t1=Y 計 3 件（Henry Morgan / Jack Sparrow / Stede Bonnet）
-- to_t2=Y 計 8 件（Stede Bonnet を含む残り全員）
SELECT
    pirate_name,
    booty_amount,
    rank,
    ship_name,
    CASE
        WHEN booty_amount > 700 THEN 'Y' -- 条件A: t1 のみ
        WHEN booty_amount < 100 THEN 'Y' -- 条件C: t1 と t2 の両方
        ELSE 'N'
    END AS to_t1,
    CASE
        WHEN rank = 'First Mate' THEN 'Y' -- 条件B: t2 のみ
        WHEN booty_amount < 100 THEN 'Y' -- 条件C: t1 と t2 の両方
        WHEN booty_amount <= 700 THEN 'Y' -- ELSE : t2 のみ
        ELSE 'N'
    END AS to_t2
FROM src
ORDER BY booty_amount DESC;


-- ============================================================
-- STEP 3: INSERT（マルチテーブル）の実行
-- ============================================================

INSERT ALL
    -- 条件A: 戦利品が 700 超 → t1 のみ
    WHEN booty_amount > 700 THEN
        INTO t1

    -- 条件B: ランクが First Mate → t2 のみ
    WHEN rank = 'First Mate' THEN
        INTO t2

    -- 条件C: 戦利品が 100 未満 → t1 と t2 の両方（2 行の WHEN を並べる）
    WHEN booty_amount < 100 THEN
        INTO t1
    WHEN booty_amount < 100 THEN
        INTO t2

    -- ELSE: 上記以外 → t2 のみ
    ELSE
        INTO t2
SELECT * FROM src;


-- ============================================================
-- STEP 4: 実行後の検証
-- ============================================================

-- 4-1. 件数確認
-- 想定: t1=3 / t2=8
SELECT 't1' AS table_name, COUNT(*) AS row_count FROM t1
UNION ALL
SELECT 't2', COUNT(*) FROM t2;

-- 4-2. t1 の内容
-- 想定: Henry Morgan(1000) / Jack Sparrow(800) / Stede Bonnet(50) の 3 件
SELECT 't1' AS target_table, pirate_name, booty_amount, rank, ship_name
FROM t1
ORDER BY booty_amount DESC;

-- 4-3. t2 の内容
-- 想定: Stede Bonnet を含む残り 8 件
SELECT 't2' AS target_table, pirate_name, booty_amount, rank, ship_name
FROM t2
ORDER BY booty_amount DESC;

-- 4-4. 条件 C（両方入れ）の検証: Stede Bonnet が t1 と t2 の両方に入っているか
-- 想定: 2 件（t1 側 / t2 側 で各 1 件）
SELECT 't1' AS target_table, pirate_name, booty_amount FROM t1 WHERE booty_amount < 100
UNION ALL
SELECT 't2', pirate_name, booty_amount FROM t2 WHERE booty_amount < 100;
