-- ============================================================
-- Frosty Friday Week 101 - 別解比較フェーズ
-- INSERT（マルチテーブル） vs 個別INSERT vs Dynamic Tables vs dbt を6軸で検証
--
-- 実行前提:
-- ・01_準備フェーズ.sql 実行済み（src テーブル / dbt プロジェクト準備含む）
-- ・dbt を比較に含める場合、SECTION 0 で src をリセットした直後（src=10 の状態）に
--   Snowsight Workspaces で「Run all」「Test」を実行しておく
--   → SECTION 1-4 の 4 手法件数比較で dbt も t1=3 / t2=8 に揃う
--
-- 比較対象（4方法）:
-- - INSERT（マルチテーブル） → 接尾辞 _mi（※ 実装は INSERT ALL を使用）
-- - 個別INSERT × 2 → 接尾辞 _ind
-- - Dynamic Tables × 2 → 接尾辞 _dt（コスト比較用に _dt_large も SECTION 5 で作成）
-- - dbt Projects on Snowflake × 2 → 接尾辞 _dbt（Workspaces で別途実行）
--
-- 比較軸（6軸 / 3者目線）:
-- 開発者目線: ①記述量・実装のしやすさ ②機能の表現力
-- 利用者目線: ③データ鮮度 ④リネージ
-- 運用者目線: ⑤コスト（スキャン効率） ⑥自動化・スケジューリング
--
-- 実行ロール: FROSTY_FRIDAY_ROLE
-- ============================================================

-- ============================================================
-- 比較対象の選定理由
-- ------------------------------------------------------------
-- Snowflake ネイティブで「複数テーブルへの振り分け」を実装する手段は
-- 多岐にわたる。本検証では以下 4 手法に絞り込んだ。
--
-- ============================================================
-- ▶ 採用した 4 手法
-- ============================================================
--
--  ① INSERT（マルチテーブル）
--      ・位置づけ : 今回のテーマそのもの
--      ・選定理由 : 比較の基準点として外せない
--      ・補足     : 実装としては INSERT ALL / INSERT FIRST の 2 構文があり、
--                  本検証では INSERT ALL を採用（応用編 SECTION 2 で両者の差を実証済み）
--
--  ② 個別 INSERT × 2
--      ・位置づけ : INSERT（マルチテーブル）の最も直接的な代替（命令型 / 物理書き込み）
--      ・選定理由 : 「マルチか否か」の差だけを切り出せる
--                  → INSERT（マルチテーブル）の優位点をフェアに浮き彫りにできる
--
--  ③ Dynamic Tables（DT）
--      ・位置づけ : INSERT 系（命令型）に対する「宣言型」のパラダイム代表
--      ・選定理由 : 鮮度・自動追従・リネージなど INSERT 系にない特性
--                  2024 GA・日本リージョン対応済で現代的選択肢として外せない
--
--  ④ dbt Projects on Snowflake（SECTION 7 マトリクスのみで評価）
--      ・位置づけ : SQL レイヤを超えた「運用フレームワーク」の代表
--      ・選定理由 : チーム開発・リネージ可視化・テスト管理の観点
--                  2025-11 に Snowsight 内で GA したため対象に含める
--
-- ============================================================
-- ▶ 比較対象から外したもの
-- ============================================================
--
-- ◯ カテゴリA: SQL 機能としては存在するが、要件不一致で除外
--
--  ・View
--      → 物理書き込みなし、参照のたびに SELECT を再計算
--      → 「テーブルへの書き込み」をテーマとする本検証と関心領域が違う
--
--  ・Materialized View
--      → JOIN / サブクエリ / UNION / CASE 等に制約あり
--      → ELSE を含む今回の振り分けロジック自体を表現できない
--
--  ・MERGE
--      → 単一テーブル対象で「マルチテーブル」要件を満たさない
--      → INSERT（マルチテーブル）との対比は応用編 SECTION 9 で別途扱う
--
-- ◯ カテゴリB: 採用 4 手法の派生・ラップ・別言語化に分類できるため除外
--
--  ・Stored Procedure（Snowflake Scripting）
--      → 中身は INSERT 文を BEGIN/EXCEPTION/END で包んだだけ
--      → パラダイム的には「個別 INSERT」と同じ（ラップ層の差のみ）
--
--  ・STREAM + TASK
--      → 実体は中で INSERT（マルチテーブル） / 個別 INSERT を呼んでいる
--      → 「手法」ではなく「自動化レイヤ」（応用編 SECTION 7 で別途扱い）
--
--  ・CTAS（CREATE TABLE AS SELECT）
--      → 1 文で 1 テーブルしか作れず、マルチでは CTAS × N になる
--      → 振る舞いは「個別 INSERT の洗い替え版」と同等
--
--  ・Snowpark DataFrame API
--      → Snowflake ネイティブだが、SQL でなく Python/Scala で記述
--      → 発表テーマ「SQL での書き分け」とは別レイヤの話
--
-- ◯ カテゴリC: 検証対象外（テーマ範囲外）
--
--  ・Fivetran / Airbyte / Airflow 等の外部 ETL / オーケストレーション
--      → Snowflake ネイティブ手法の比較がテーマのため対象外
-- ============================================================

USE ROLE FROSTY_FRIDAY_ROLE;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE frosty_friday;
USE SCHEMA week101;


-- ============================================================
-- SECTION 0: 検証環境セットアップ
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- src を正準 10 件にリセットし、INSERT 系 2 手法（_mi / _ind）の
-- 宛先テーブルが空の状態で揃っていることを確認する。
-- ------------------------------------------------------------
-- 内容: src を決定論的に作り直し（01〜03 の実行順や追加データに依存せず、
-- 常に 10 件から始める）、INSERT 系 2 手法の宛先テーブル枠を初期化する。
-- （Dynamic Tables は SECTION 1、dbt は外部 Workspaces で作成）
-- ============================================================

-- ▶ 0-0: src を正準 10 件にリセット（04 を自己完結・決定論的にする）
-- ※ 01→02→03 を流すと応用編 SECTION 7 で src に 2 件追加され 12 件になる。
--   04 の件数想定（t1=3 / t2=8）を常に成立させるため、ここで作り直す。
-- ※ dbt を比較に含める場合は、この直後（src=10 の状態）に Workspaces で
--   「Run all」「Test」を実行しておくこと。
CREATE OR REPLACE TABLE src (
    pirate_name STRING,
    booty_amount NUMBER,
    rank STRING,
    ship_name STRING
);
INSERT INTO src (pirate_name, booty_amount, rank, ship_name) VALUES
    ('Blackbeard', 500, 'Captain', 'Queen Anne\'s Revenge'),
    ('Anne Bonny', 300, 'First Mate', 'Revenge'),
    ('Calico Jack', 200, 'Captain', 'Ranger'),
    ('Henry Morgan', 1000, 'Admiral', 'Oxford'),
    ('Bartholomew Roberts', 400, 'Captain', 'Royal Fortune'),
    ('Mary Read', 150, 'Quartermaster', 'Ranger'),
    ('Stede Bonnet', 50, 'Captain', 'Revenge'),
    ('Charles Vane', 250, 'Captain', 'Lark'),
    ('Jack Sparrow', 800, 'Captain', 'Black Pearl'),
    ('William Kidd', 600, 'Captain', 'Adventure Galley');

-- ▶ src の件数確認
-- 想定: src=10 件（このSECTIONで作り直すため必ず 10 件）
SELECT COUNT(*) AS src_row_count FROM src;

-- INSERT（マルチテーブル）用の宛先テーブル
CREATE OR REPLACE TABLE t1_mi (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE t2_mi (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);

-- 個別 INSERT 用の宛先テーブル
CREATE OR REPLACE TABLE t1_ind (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE t2_ind (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);

-- ▶ 実行前確認: 全 4 テーブルが空であることを確認
-- 想定: t1_mi=0 / t2_mi=0 / t1_ind=0 / t2_ind=0
SELECT 't1_mi' AS tbl, COUNT(*) AS cnt FROM t1_mi
UNION ALL SELECT 't2_mi', COUNT(*) FROM t2_mi
UNION ALL SELECT 't1_ind', COUNT(*) FROM t1_ind
UNION ALL SELECT 't2_ind', COUNT(*) FROM t2_ind;

-- Dynamic Tables は後続セクションで CREATE する（CREATE TABLE 不要）


-- ============================================================
-- SECTION 1: 軸①「記述量・実装のしやすさ」検証【開発者目線】
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- 同じ振り分けロジックを 3 手法(INSERT（マルチテーブル） / 個別 INSERT / Dynamic Tables)で
-- 実装し、すべて t1 系=3 件 / t2 系=8 件で一致することを確認する。
-- あわせて各手法の SQL 行数・記述パターンの差も視認する。
-- ------------------------------------------------------------
-- 内容: 同じ振り分けロジックを3方法で実装し、行数・複雑さを比較する
-- ▶ 振り分け条件（基礎編と同一）:
-- 条件A: booty_amount > 700 → t1 のみ
-- 条件B: rank = 'First Mate' → t2 のみ
-- 条件C: booty_amount < 100 → t1 と t2 の両方
-- ELSE → t2 のみ
-- ============================================================

-- ── 1-1: INSERT（マルチテーブル）版 ────────────────────────────────
-- 実行ロジックは1ブロック・WHEN句で完結する
INSERT ALL
    WHEN booty_amount > 700 THEN INTO t1_mi
    WHEN rank = 'First Mate' THEN INTO t2_mi
    WHEN booty_amount < 100 THEN INTO t1_mi
    WHEN booty_amount < 100 THEN INTO t2_mi
    ELSE INTO t2_mi
SELECT * FROM src;
-- 行数: INSERT文 約7行 / 1ブロックで完結

-- ── 1-2: 個別INSERT版 ──────────────────────────────────────
-- t1_ind と t2_ind の WHERE 条件を別々に書く必要がある
INSERT INTO t1_ind
SELECT * FROM src
WHERE booty_amount > 700 OR booty_amount < 100;

INSERT INTO t2_ind
SELECT * FROM src
WHERE rank = 'First Mate'
   OR booty_amount < 100
   OR (booty_amount BETWEEN 100 AND 700 AND rank != 'First Mate');
-- 行数: 2ブロック分・WHERE 条件は手動で「t1 の補集合」を組み立てる必要あり

-- ── 1-3: Dynamic Tables 版 ─────────────────────────────────
-- 宛先ごとに CREATE DYNAMIC TABLE で SELECT を宣言する
CREATE OR REPLACE DYNAMIC TABLE t1_dt
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
AS
SELECT pirate_name, booty_amount, rank, ship_name
FROM src
WHERE booty_amount > 700 OR booty_amount < 100;

CREATE OR REPLACE DYNAMIC TABLE t2_dt
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
AS
SELECT pirate_name, booty_amount, rank, ship_name
FROM src
WHERE rank = 'First Mate'
   OR booty_amount < 100
   OR (booty_amount BETWEEN 100 AND 700 AND rank != 'First Mate');
-- 行数: 個別INSERT 相当 + TARGET_LAG / WAREHOUSE 指定が追加で必要

-- ── ▶ 実行後の結果確認: 3 方法で同じ件数になることを確認 ────
-- 想定: 全方法で t1 系=3 件 / t2 系=8 件（同じ振り分けロジックなので一致するはず）
SELECT 'mi - t1' AS method_table, COUNT(*) AS cnt FROM t1_mi
UNION ALL SELECT 'mi - t2', COUNT(*) FROM t2_mi
UNION ALL SELECT 'ind - t1', COUNT(*) FROM t1_ind
UNION ALL SELECT 'ind - t2', COUNT(*) FROM t2_ind
UNION ALL SELECT 'dt - t1', COUNT(*) FROM t1_dt
UNION ALL SELECT 'dt - t2', COUNT(*) FROM t2_dt
ORDER BY method_table;

-- ── ▶ 1-4: dbt を含めた「4 手法」の件数一致（クリーンデータ src=10） ────
-- ★ ここが 4 手法すべてが同じ振り分け結果に揃う唯一のクリーンな地点。
--   SECTION 3 以降は鮮度検証のため意図的に src を変化させ各手法を乖離させ、
--   さらに SECTION 5 で _mi / _ind を src_large（大量データ）へ作り替える。
--   よって「全手法が一致する」証明は、破壊的な検証に入る前のここで行う。
-- ※ dbt は外部（Workspaces）で作成するため、SECTION 0 リセット後（src=10）に
--   「Run all」を実行済みの場合のみ実行可能。未実行なら t1_dbt が無くエラーになる
--   （その場合は上の 3 手法版で代替し、dbt は SECTION 7 で個別確認する）。
-- 想定: 全 4 手法で t1 系=3 件 / t2 系=8 件
SELECT 'mi - t1' AS method_table, COUNT(*) AS cnt FROM t1_mi
UNION ALL SELECT 'mi - t2', COUNT(*) FROM t2_mi
UNION ALL SELECT 'ind - t1', COUNT(*) FROM t1_ind
UNION ALL SELECT 'ind - t2', COUNT(*) FROM t2_ind
UNION ALL SELECT 'dt - t1', COUNT(*) FROM t1_dt
UNION ALL SELECT 'dt - t2', COUNT(*) FROM t2_dt
UNION ALL SELECT 'dbt - t1', COUNT(*) FROM t1_dbt
UNION ALL SELECT 'dbt - t2', COUNT(*) FROM t2_dbt
ORDER BY method_table;

-- ── ▶ 軸①「記述量」定量計測: QUERY_HISTORY から実機 SQL の文字数を取得 ───
-- 各手法を実装したクエリの query_text 長さ（半角換算文字数）を集計する
-- ※ dbt は Snowsight Workspaces で実行された CREATE TABLE AS SELECT も
--   同セッション内なら QUERY_HISTORY_BY_SESSION で取れる
SELECT
    CASE
        WHEN query_text ILIKE 'INSERT ALL%t1_mi%' THEN 'INSERT（マルチテーブル）'
        WHEN query_text ILIKE 'INSERT INTO t1_ind%' THEN '個別 INSERT (t1 文)'
        WHEN query_text ILIKE 'INSERT INTO t2_ind%' THEN '個別 INSERT (t2 文)'
        WHEN query_text ILIKE 'CREATE OR REPLACE DYNAMIC TABLE t1_dt%' THEN 'Dynamic Tables (t1 文)'
        WHEN query_text ILIKE 'CREATE OR REPLACE DYNAMIC TABLE t2_dt%' THEN 'Dynamic Tables (t2 文)'
    END AS method,
    LENGTH(query_text) AS sql_length_chars,
    LEFT(query_text, 80) AS query_preview
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE (query_text ILIKE 'INSERT ALL%t1_mi%'
    OR query_text ILIKE 'INSERT INTO t1_ind%'
    OR query_text ILIKE 'INSERT INTO t2_ind%'
    OR query_text ILIKE 'CREATE OR REPLACE DYNAMIC TABLE t1_dt%'
    OR query_text ILIKE 'CREATE OR REPLACE DYNAMIC TABLE t2_dt%')
ORDER BY start_time DESC
LIMIT 10;
-- ↑ 実機の文字数（軸①の根拠数値）。dbt 部分は SECTION 7 実行後に再集計


-- ============================================================
-- SECTION 2: 軸②「機能の表現力」検証【開発者目線】
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- 「複数テーブル同時書き込み」「トランザクション原子性」「upsert」の
-- 3 機能について、3 手法それぞれで実現できるかを確認する。
-- 特に upsert は Dynamic Tables だけが宣言的に対応できることを見る。
-- ------------------------------------------------------------
-- 内容: 3要素（複数テーブル同時書き込み・upsert・原子性）の
-- 各方法での実現可否を検証する
-- ============================================================

-- ── 2-1: 複数テーブル同時書き込み ──────────────────────────
-- INSERT（マルチテーブル）: ◎ 1ブロックで複数 INTO 可能（SECTION 1 で実証済み）
-- 個別INSERT: △ 複数文を書けば実現可・ただし別クエリ扱い
-- Dynamic Tables: ○ 複数の DT を別々に定義する形（同時実行ではない）

-- ── 2-2: トランザクション原子性 ────────────────────────────
-- INSERT（マルチテーブル）: ◎ 単一文で全 INTO が原子的（応用編セクション5で実証済み）
-- 個別INSERT: △ BEGIN/COMMIT で明示ラップが必要
BEGIN;
INSERT INTO t1_ind VALUES ('Atomic Test', 999, 'Captain', 'TestShip');
INSERT INTO t2_ind VALUES ('Atomic Test', 999, 'Captain', 'TestShip');
COMMIT;
-- ↑ 明示TXで原子性は確保できるが、書き忘れリスクあり
-- 後片付け
DELETE FROM t1_ind WHERE pirate_name = 'Atomic Test';
DELETE FROM t2_ind WHERE pirate_name = 'Atomic Test';

-- Dynamic Tables: × 個別 DT のリフレッシュは独立しており同時保証なし
-- （ただし依存DAGで論理的な順序保証はある）

-- ── 2-3: upsert（既存データの更新） ────────────────────────
-- INSERT（マルチテーブル）: × INSERT 専用、重複行が増えるだけ
-- 個別INSERT: × 同上
-- Dynamic Tables: ◎ ソースの UPDATE を検知して自動再計算（宣言的upsert）

-- DT の upsert 挙動を確認: src を更新 → DT が自動追従
UPDATE src SET booty_amount = 1500 WHERE pirate_name = 'Jack Sparrow';

-- DT の手動リフレッシュ（TARGET_LAG 待たずに即時反映させる）
ALTER DYNAMIC TABLE t1_dt REFRESH;
ALTER DYNAMIC TABLE t2_dt REFRESH;

-- 結果確認: Jack Sparrow の booty_amount が 1500 に更新されている
SELECT 't1_dt' AS tbl, pirate_name, booty_amount FROM t1_dt WHERE pirate_name = 'Jack Sparrow'
UNION ALL
SELECT 't1_mi', pirate_name, booty_amount FROM t1_mi WHERE pirate_name = 'Jack Sparrow';
-- DT は 1500（自動追従）/ INSERT（マルチテーブル）は 800（古いまま、再実行が必要）

-- src を元に戻す
UPDATE src SET booty_amount = 800 WHERE pirate_name = 'Jack Sparrow';


-- ============================================================
-- SECTION 3: 軸③「データ鮮度」検証【利用者目線】
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- src に新規レコードを追加した後、_mi / _ind は再実行しないと反映されないが、
-- _dt(Dynamic Tables) は TARGET_LAG に従って自動追従することを確認する。
-- ------------------------------------------------------------
-- 内容: ソース更新→宛先反映までのタイミングを3方法で比較する
-- ============================================================

-- ソースに新規海賊を追加（応用編 SECTION 7 の Long John Silver と被らない別名を採用）
INSERT INTO src VALUES ('Henry Every', 800, 'Captain', 'Fancy II');

-- ── 3-1: 各方法の即時反映状況を確認 ────────────────────────
-- INSERT（マルチテーブル） (_mi): 再実行していないので追加データは入っていない
SELECT 'mi' AS method, COUNT(*) AS cnt FROM t1_mi WHERE pirate_name = 'Henry Every'
UNION ALL
-- 個別INSERT (_ind): 同様に再実行していないので未反映
SELECT 'ind', COUNT(*) FROM t1_ind WHERE pirate_name = 'Henry Every'
UNION ALL
-- Dynamic Tables (_dt): TARGET_LAG=1min なので最大1分以内に自動反映
-- 即時確認したい場合は ALTER DYNAMIC TABLE ... REFRESH を実行
SELECT 'dt', COUNT(*) FROM t1_dt WHERE pirate_name = 'Henry Every';

-- DT を手動リフレッシュ（待たずに即時反映）
ALTER DYNAMIC TABLE t1_dt REFRESH;
ALTER DYNAMIC TABLE t2_dt REFRESH;

-- 再確認: dt のみが反映済みになる
SELECT 'mi' AS method, COUNT(*) AS cnt FROM t1_mi WHERE pirate_name = 'Henry Every'
UNION ALL SELECT 'ind', COUNT(*) FROM t1_ind WHERE pirate_name = 'Henry Every'
UNION ALL SELECT 'dt', COUNT(*) FROM t1_dt WHERE pirate_name = 'Henry Every';

-- DT のリフレッシュ履歴を確認（鮮度の証跡）
SELECT name, refresh_action, state, refresh_start_time, refresh_end_time
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
           NAME_PREFIX => CONCAT(CURRENT_DATABASE(), '.', CURRENT_SCHEMA(), '.T')
       ))
WHERE name IN ('T1_DT', 'T2_DT')
ORDER BY refresh_start_time DESC
LIMIT 5;


-- ============================================================
-- SECTION 4: 軸④「リネージ」検証【利用者目線】
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- Dynamic Tables は GET_DDL で「ソースを SELECT する CREATE 文」がそのまま
-- メタデータに残るためリネージが自動で取得できる一方、
-- 通常テーブル(_mi / _ind) は CREATE TABLE 文しか残らず依存元が記録されない
-- ことを確認する。
-- ------------------------------------------------------------
-- 内容: 各方法でソース→宛先の依存関係をどう追跡できるかを確認
-- ============================================================

-- ── 4-1: Dynamic Tables のリネージ（CREATE 文に依存元が記録されている） ────
-- DT は「結果集合を宣言」する仕組みなので、SELECT 文（=依存元）が
-- そのまま CREATE 文として保持されている → GET_DDL で即時取得可能
SELECT GET_DDL('DYNAMIC_TABLE', 'T1_DT') AS t1_dt_definition;
-- ↑ 出力に「FROM src」が含まれることを確認 → 依存元が src であると即時判明

-- ACCOUNT_USAGE 経由の依存関係取得（運用視点）
-- ※ ACCOUNT_USAGE.OBJECT_DEPENDENCIES は最大 2 時間の遅延があるため、
-- 即時確認したい場合は Snowsight UI の Lineage タブを使う
SELECT referenced_database, referenced_schema, referenced_object_name,
       referencing_database, referencing_schema, referencing_object_name,
       dependency_type
FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
WHERE referencing_object_name IN ('T1_DT', 'T2_DT')
  AND referenced_object_name = 'SRC'
ORDER BY referencing_object_name;

-- Snowsight UI: 左メニュー → Data → Databases → T1_DT → Lineage タブで
-- 依存 DAG（src → T1_DT）がグラフ表示される（即時反映）

-- ── 4-2: INSERT（マルチテーブル） / 個別 INSERT のリネージ ──────────
-- 通常テーブルは CREATE TABLE 文しかメタデータに残らず、依存元が記録されないことを示す

-- (a) DT との対比: 通常テーブル T1_MI の GET_DDL を取得
-- T1_DT には「FROM src」が含まれていたが、T1_MI には CREATE TABLE しか残らない
SELECT GET_DDL('TABLE', 'T1_MI') AS t1_mi_definition;
-- ↑ 「CREATE OR REPLACE TABLE T1_MI (...列定義...);」のみ。
--    どこから INSERT されたかの情報は存在しない（=依存元が不明）

-- (b) OBJECT_DEPENDENCIES でも通常テーブルは記録されないことを確認
SELECT 'T1_MI / T1_IND の依存関係' AS target, COUNT(*) AS dependency_rows
FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
WHERE referencing_object_name IN ('T1_MI', 'T1_IND')
  AND referenced_object_name = 'SRC';
-- ↑ 0 件が返ることを期待（DT の T1_DT / T2_DT のみ依存関係が記録される）

-- (c) 通常テーブルでリネージを取るには QUERY_HISTORY を解析する必要がある
SELECT query_id,
       LEFT(query_text, 80) AS query_summary,
       query_type,
       start_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE query_type IN ('INSERT', 'MULTI_TABLE_INSERT')
  AND (query_text ILIKE '%t1_mi%' OR query_text ILIKE '%t1_ind%') -- AND/OR の優先順位を括弧で明示
ORDER BY start_time DESC
LIMIT 5;
-- ↑ クエリ履歴から間接的に追跡する必要あり（自動DAG化はされない）

-- ── ▶ 軸④「リネージ」定量化: 4 手法の依存記録の有無を 0/1 に集約 ────
-- ACCOUNT_USAGE.OBJECT_DEPENDENCIES に「src を依存元として持つレコード」が
-- 何件あるかを各手法ごとに集計する（dbt は SECTION 7 実行後に値が入る）
SELECT 'INSERT（マルチテーブル）' AS method, 'T1_MI' AS target_table,
       (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
        WHERE referencing_object_name = 'T1_MI' AND referenced_object_name = 'SRC') AS lineage_recorded
UNION ALL
SELECT '個別 INSERT', 'T1_IND',
       (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
        WHERE referencing_object_name = 'T1_IND' AND referenced_object_name = 'SRC')
UNION ALL
SELECT 'Dynamic Tables', 'T1_DT',
       (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
        WHERE referencing_object_name = 'T1_DT' AND referenced_object_name = 'SRC')
UNION ALL
SELECT 'dbt', 'T1_DBT',
       (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
        WHERE referencing_object_name = 'T1_DBT' AND referenced_object_name = 'SRC')
ORDER BY method;
-- ↑ Dynamic Tables / dbt = 1（自動記録あり）、INSERT 系 = 0（記録なし）が想定
-- ※ ACCOUNT_USAGE は最大 2 時間の遅延。即時確認は GET_DDL（上の 4-1/4-2 で実施）


-- ============================================================
-- SECTION 5: 軸⑤「コスト（スキャン効率）」検証【運用者目線】
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- INSERT（マルチテーブル）（1 クエリ・1 スキャン）と
-- 個別 INSERT（2 クエリ・2 スキャン）の bytes_scanned の差を
-- QUERY_HISTORY で確認する。Dynamic Tables の増分リフレッシュも併せて見る。
-- ------------------------------------------------------------
-- 内容: 小データでは bytes_scanned 差が見えにくいため、
-- 約 110 万行のダミーデータ（src_large）で実測する
-- ============================================================

-- ── 5-0-pre: 大量データ検証用の高速ウェアハウスに切替 ──────
-- ▶ なぜ必要か:
-- 約 110 万行の INSERT / フルリフレッシュを既定の COMPUTE_WH（XSMALL 想定）で
-- 流すと登壇中に数分かかることがある。登壇のテンポを保つため、この SECTION 5 の
-- 重い処理だけ、大きいサイズの WH（compute_wh_perf）で実行する。
--
-- ▶ この WH は 01_準備フェーズ.sql のフェーズ D で登壇前に作成済みの想定。
--   サイズ（WAREHOUSE_SIZE）の調整も 01 側で行う（★要調整）。
--   ここでは USE で切り替えるだけ。SECTION 5 末尾（5-3）で COMPUTE_WH に戻す。
--
-- ▶ 比較の妥当性: bytes_scanned（スキャンしたデータ量）は WH サイズに依存しない。
--   WH を大きくしても「個別 INSERT のスキャン量が約 2 倍」という軸⑤の結論は不変。
--   速くなるのは execution_time（処理時間）だけ。
USE WAREHOUSE compute_wh_perf;

-- ── 5-0: 大量のダミーデータを生成（src_large） ──────────
-- src（11 件＝SECTION 0 の初期 10 + SECTION 3 で追加した Henry Every）を
-- CROSS JOIN GENERATOR で増幅して約 110 万行に。これによりスキャン量の
-- 理論差（INSERT ALL=1 回 vs 個別 INSERT=2 回）が数値ベースで観測できる。
CREATE OR REPLACE TABLE src_large AS
SELECT src.*
FROM src
       CROSS JOIN TABLE(GENERATOR(ROWCOUNT => 100000)); -- 11件 × 10万 = 約110万行（src の件数次第で増減）

-- ▶ 実行前確認: src_large の行数
-- 想定: 約 110 万件（src の件数 × 10 万）
SELECT COUNT(*) AS src_large_row_count FROM src_large;

-- 比較用に既存テーブルを TRUNCATE して履歴を新しくする
TRUNCATE TABLE t1_mi; TRUNCATE TABLE t2_mi;
TRUNCATE TABLE t1_ind; TRUNCATE TABLE t2_ind;

-- INSERT（マルチテーブル）: 1 クエリで完結 → src_large スキャン 1 回
INSERT ALL
    WHEN booty_amount > 700 THEN INTO t1_mi
    WHEN rank = 'First Mate' THEN INTO t2_mi
    WHEN booty_amount < 100 THEN INTO t1_mi
    WHEN booty_amount < 100 THEN INTO t2_mi
    ELSE INTO t2_mi
SELECT * FROM src_large;

-- 個別 INSERT: 2 クエリ → src_large スキャン 2 回
INSERT INTO t1_ind SELECT * FROM src_large WHERE booty_amount > 700 OR booty_amount < 100;
INSERT INTO t2_ind SELECT * FROM src_large
WHERE rank = 'First Mate' OR booty_amount < 100
   OR (booty_amount BETWEEN 100 AND 700 AND rank != 'First Mate');

-- Dynamic Tables: src_large を参照する DT を新規作成（約 110 万行をフルリフレッシュ）
-- ・WAREHOUSE は高速 WH（compute_wh_perf）を指定 → 初回フルリフレッシュを高速化
-- ・TARGET_LAG は長め（60 分）にする。src_large は変化しないので増分リフレッシュは
--   発生せず、登壇中に約 110 万行のリフレッシュが何度も走ってクレジットを浪費するのを防ぐ。
--   観測したいのは「初回フルリフレッシュ」のスキャン量・時間（5-2 で確認）。
CREATE OR REPLACE DYNAMIC TABLE t1_dt_large
    TARGET_LAG = '60 minute'         -- 登壇中の再リフレッシュ抑止（観測対象は初回フルのみ）
    WAREHOUSE = compute_wh_perf      -- ★【要調整】サイズは 01 フェーズ D で調整
AS
SELECT pirate_name, booty_amount, rank, ship_name
FROM src_large
WHERE booty_amount > 700 OR booty_amount < 100;

CREATE OR REPLACE DYNAMIC TABLE t2_dt_large
    TARGET_LAG = '60 minute'
    WAREHOUSE = compute_wh_perf
AS
SELECT pirate_name, booty_amount, rank, ship_name
FROM src_large
WHERE rank = 'First Mate'
   OR booty_amount < 100
   OR (booty_amount BETWEEN 100 AND 700 AND rank != 'First Mate');

-- ── 5-1: INSERT（マルチテーブル）と 個別 INSERT のスキャン量比較 ────
-- 直近の INSERT 履歴から bytes_scanned を取得
SELECT LEFT(query_text, 60) AS query_summary,
       query_type,
       bytes_scanned,
       rows_produced,
       execution_time / 1000.0 AS execution_sec,
       start_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE (query_text ILIKE '%t1_mi%' OR query_text ILIKE '%t2_mi%'
    OR query_text ILIKE '%t1_ind%' OR query_text ILIKE '%t2_ind%')
  AND query_text ILIKE '%src_large%'
ORDER BY start_time DESC
LIMIT 10;
-- ↑ INSERT（マルチテーブル）は MULTI_TABLE_INSERT で 1 行、個別 INSERT は INSERT で 2 行
-- ↑ 約 110 万行スキャンの実測で、個別 INSERT の bytes_scanned 合計が約 2 倍になることが見える

-- ▶ 方式ごとに集計（実機の数値で約 2 倍を確認する）
WITH recent_large_inserts AS (
    SELECT
        CASE WHEN query_text ILIKE 'INSERT ALL%' THEN 'INSERT（マルチテーブル）' ELSE '個別 INSERT' END AS method,
        bytes_scanned,
        rows_produced,
        execution_time
    FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
    WHERE (query_text ILIKE '%t1_mi%' OR query_text ILIKE '%t2_mi%'
        OR query_text ILIKE '%t1_ind%' OR query_text ILIKE '%t2_ind%')
      AND query_text ILIKE '%src_large%'
    ORDER BY start_time DESC
    LIMIT 3
)
SELECT
    method,
    COUNT(*) AS statement_count,
    SUM(bytes_scanned) AS total_bytes_scanned,
    SUM(rows_produced) AS total_rows_produced,
    SUM(execution_time) / 1000.0 AS total_execution_sec
FROM recent_large_inserts
GROUP BY method
ORDER BY method;
-- ↑ 想定: 個別 INSERT の total_bytes_scanned が INSERT（マルチテーブル）の約 2 倍

-- ── 5-2: Dynamic Tables のスキャン量（DT 専用ビューで取得） ────
-- DT のリフレッシュは QUERY_HISTORY に現れないため
-- INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY で取得する
SELECT name,
       refresh_action,
       state,
       refresh_start_time,
       refresh_end_time,
       DATEDIFF('millisecond', refresh_start_time, refresh_end_time) AS duration_ms
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
           NAME_PREFIX => CONCAT(CURRENT_DATABASE(), '.', CURRENT_SCHEMA(), '.T')
       ))
WHERE name IN ('T1_DT_LARGE', 'T2_DT_LARGE')
ORDER BY refresh_start_time DESC
LIMIT 5;
-- ↑ 初回はフルスキャン（約 110 万行）、以降は増分のみ（差分スキャンで安い）
-- ↑ refresh_action = INITIAL / INCREMENTAL の別が分かる

-- ── 5-3: 既定ウェアハウスに戻す ──────────────────────────
-- SECTION 5 の重い処理が終わったので、以降のセクションは通常の COMPUTE_WH で実行する。
-- （compute_wh_perf は自動停止するので残してよい。完全削除は SECTION 9 参照）
USE WAREHOUSE COMPUTE_WH;


-- ============================================================
-- SECTION 6: 軸⑥「自動化・スケジューリング」検証【運用者目線】
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- INSERT（マルチテーブル）/ 個別 INSERT は TASK 構築(WAREHOUSE / SCHEDULE 指定)が必要、
-- Dynamic Tables は TARGET_LAG 指定だけで自動化できることを確認する。
-- ------------------------------------------------------------
-- 内容: 定期実行・差分処理のセットアップ容易性を比較する
-- ============================================================

-- ── 6-1: INSERT（マルチテーブル） / 個別INSERT は TASK でラップ ────
-- TASK を作成して 5分ごとにINSERT（マルチテーブル）を実行する例
CREATE OR REPLACE TASK task_refresh_mi
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '5 MINUTE'
AS
    INSERT ALL
        WHEN booty_amount > 700 THEN INTO t1_mi
        WHEN rank = 'First Mate' THEN INTO t2_mi
        WHEN booty_amount < 100 THEN INTO t1_mi
        WHEN booty_amount < 100 THEN INTO t2_mi
        ELSE INTO t2_mi
    SELECT * FROM src;

-- TASK を有効化（実演しない場合はコメントアウト推奨）
-- ALTER TASK task_refresh_mi RESUME;

-- 必要な要素: WAREHOUSE指定 / SCHEDULE指定 / TASK権限 / RESUME操作
-- 差分処理にしたい場合は STREAM の併用が追加で必要（応用編セクション7参照）

-- 個別INSERT も同じ要領で TASK 化可能（実装は省略・実演時に口頭補足）
-- 個別INSERT は複数文なので、スクリプトブロックで TASK の AS 句に包む必要がある
-- 例:
-- CREATE TASK task_refresh_ind WAREHOUSE = COMPUTE_WH SCHEDULE = '5 MINUTE' AS
-- EXECUTE IMMEDIATE $$
-- BEGIN
-- INSERT INTO t1_ind SELECT * FROM src WHERE booty_amount > 700 OR booty_amount < 100;
-- INSERT INTO t2_ind SELECT * FROM src
-- WHERE rank = 'First Mate' OR booty_amount < 100
-- OR (booty_amount BETWEEN 100 AND 700 AND rank != 'First Mate');
-- END;
-- $$;
-- INSERT（マルチテーブル）版と比べて「スクリプトブロックの記述が増える」点が違い

-- ── 6-2: Dynamic Tables は TARGET_LAG だけで自動化 ─────────
-- 既に CREATE 時に TARGET_LAG='1 minute' を指定済み
-- → 追加のスケジューリング設定は不要、Snowflakeが自動制御

-- DT の自動リフレッシュ状況を確認
SHOW DYNAMIC TABLES LIKE 'T_DT';
SELECT "name", "target_lag", "scheduling_state", "last_suspended_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- 後片付け（TASK 削除）
DROP TASK IF EXISTS task_refresh_mi;


-- ============================================================
-- SECTION 7: dbt Projects on Snowflake の検証
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- dbt は SQL ファイル内で直接実行できないため、Snowsight Workspaces で
-- 「Run all」/「Test」を実行した【後に】、以下の SQL で結果を確認する。
-- 確認項目:
--   ① dbt run で t1_dbt / t2_dbt が作成されたこと
--   ② 件数が他手法と一致すること（横並び比較は SECTION 1-4 で実施済み。ここでは dbt 単独で確認）
--   ③ dbt の Lineage（src → t1_dbt / t2_dbt）が記録されていること
--   ④ dbt test が PASS していること
-- ------------------------------------------------------------
-- 内容: 「組織で運用」観点の dbt が、他の SQL ベース手法と比べて
-- リネージ・テスト・スケジュール面でどう優位かを実機で確認する。
-- ============================================================

-- ▶ 事前準備:
-- 01_準備フェーズ.sql のフェーズ C を実施済みで、Snowsight Workspaces 上で
-- 以下を実行済みであること。
--   1. Workspaces 右上「Run all」をクリック（= dbt run 相当）
--   2. 続けて「Test」をクリック（= dbt test 相当）
-- → 完了すると week101 スキーマに t1_dbt / t2_dbt が作成される。
-- ※ Run all は SECTION 0 のリセット後（src=10）に実行しておくこと（SECTION 1-4 と件数を揃えるため）。

-- ── 7-1: dbt が作成したテーブルの存在と件数を確認 ──────────
-- 想定: t1_dbt=3 / t2_dbt=8（src=10 で Run all した場合）
SELECT 't1_dbt' AS tbl, COUNT(*) AS cnt FROM t1_dbt
UNION ALL SELECT 't2_dbt', COUNT(*) FROM t2_dbt;

-- ── 7-2: 4 手法の件数一致は SECTION 1-4 で実証済み（ここでは再比較しない） ──
-- ※ 4 手法（_mi / _ind / _dt / _dbt）の横並び件数比較は、すべてが同条件で揃う
--   クリーンな地点＝SECTION 1-4（src=10）で実施済み。
--   この SECTION 7 の時点では既に
--     ・SECTION 3 で src に Henry Every を追加し _dt のみ自動追従（鮮度検証）
--     ・SECTION 5 で _mi / _ind を src_large（大量データ）へ作り替え（コスト検証）
--   という意図的な操作を経ているため、ここで横並びにしても一致しない。
--   → 一致の実証はクリーンな SECTION 1-4 に集約する、というのが本ファイルの設計。
--   ここでは以降、dbt 固有の価値（リネージ・DDL・テスト）の確認に集中する。

-- ── 7-3: dbt 由来テーブルのリネージ確認（軸④の補完） ──────
-- dbt は ref() で依存関係を宣言するため、内部的には CREATE TABLE AS SELECT
-- として実行され、Snowflake 側にも依存元（src）が記録される。
SELECT referenced_database, referenced_schema, referenced_object_name,
       referencing_database, referencing_schema, referencing_object_name,
       dependency_type
FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
WHERE referencing_object_name IN ('T1_DBT', 'T2_DBT')
  AND referenced_object_name = 'SRC'
ORDER BY referencing_object_name;
-- ※ ACCOUNT_USAGE は最大 2 時間の遅延あり。即時確認なら Workspaces の
--   「Lineage」タブで src → t1_dbt / t2_dbt の DAG をグラフ表示できる。
--   これは Snowflake ネイティブのリネージとは別に、dbt docs としても出力可能。

-- ── 7-4: dbt の CREATE 文を確認（実装パラダイムの確認） ───
-- dbt は内部的に CREATE OR REPLACE TABLE AS SELECT を発行している
SELECT GET_DDL('TABLE', 'T1_DBT') AS t1_dbt_definition;
-- ↑ DT と同様に FROM src が CREATE 文に残るため、リネージ取得が可能

-- ── 7-5: dbt test の結果確認 ────────────────────────────
-- 01 の schema.yml で not_null テストを定義済み（pirate_name / booty_amount）
-- Workspaces の「Test」ボタンを押した直後にここを実行すると履歴が見える
SELECT LEFT(query_text, 100) AS test_query,
       execution_status,
       start_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE query_text ILIKE '%not_null%'
   OR query_text ILIKE '%dbt_test%'
ORDER BY start_time DESC
LIMIT 10;
-- ↑ execution_status='SUCCESS' で 0 件返れば test PASS（dbt の慣習）

-- ▶ こういう場面で使う:
-- 複数人で SQL 資産を管理し、リネージ・テスト・スケジュールを
-- コードとして残したい組織開発の場面。


-- ============================================================
-- SECTION 8: 6軸 × 4方法 マトリクス結果まとめ
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- 6 軸 × 4 手法の評定マトリクスで、各手法の強み・弱みを総括し、
-- 「目的に応じた使い分け」の結論を聴衆に提示する。
-- ------------------------------------------------------------
-- 内容: 各セクションの検証結果を一覧化（発表用サマリ）
--
-- ┌────────────────────┬─────────────┬──────────────┬───────────────┬──────────────────┐
-- │ 軸 │ INSERT（マルチテーブル） │ 個別INSERT │ Dynamic Tables│ dbt on Snowflake │
-- ├────────────────────┼─────────────┼──────────────┼───────────────┼──────────────────┤
-- │ ①記述量 │ ◎ SQL1発 │ △ 文ごと分割 │ ○ 宣言的×N │ △ yml+sql×N │
-- │ ②機能表現力 │ ◎ 同時/原子的│ ○ TX明示必要 │ ◎ upsert可 │ ○ refで連結 │
-- │ ③データ鮮度 │ × 手動再実行 │ × 手動再実行 │ ◎ TARGET_LAG │ ○ スケジュール │
-- │ ④リネージ │ × 履歴解析 │ × 履歴解析 │ ◎ ネイティブ │ ◎ dbt docs │
-- │ ⑤コスト │ ◎ 1スキャン │ △ Nスキャン │ ○ 増分 │ △ Nスキャン │
-- │ ⑥自動化 │ △ TASK必要 │ △ TASK必要 │ ◎ 設定不要 │ ○ scheduler必要 │
-- └────────────────────┴─────────────┴──────────────┴───────────────┴──────────────────┘
--
-- 発表ストーリー:
-- 開発者目線: INSERT（マルチテーブル）は「書く」段階で最強（①②）
-- 利用者目線: Dynamic Tables / dbt が「使う」段階で強い（③④）
-- 運用者目線: INSERT（マルチテーブル）はコスト◎だが自動化△、DTは設定不要で運用◎
--
-- 結論:
-- 「単発ジョブで複数テーブルに振り分けるならINSERT（マルチテーブル）」
-- 「定常パイプラインなら Dynamic Tables」
-- 「組織で運用するなら dbt on Snowflake」
-- ── 目的に応じた使い分けが正解
-- ============================================================

-- 検証で作成したオブジェクトの一覧（4 手法 + 大量データ系を網羅）
SELECT table_name, table_type, row_count
FROM information_schema.tables
WHERE table_schema = 'WEEK101'
  AND (table_name LIKE '%_MI' OR
        table_name LIKE '%_IND' OR
        table_name LIKE '%_DT' OR
        table_name LIKE '%_DT_LARGE' OR
        table_name LIKE '%_DBT' OR
        table_name = 'SRC_LARGE')
ORDER BY table_name;


-- ─────────────────────────────────────────────────────────────
-- ▶ 実機定量マトリクス（実行結果から集約した数値）
-- ─────────────────────────────────────────────────────────────
-- SECTION 1〜7 の実行結果を CTE で集約し、4 手法 × 6 軸の数値マトリクスを出力
-- 数値の取得元:
--   ① 記述量      : 実機（INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION）
--   ② 機能表現力  : 事実テーブル（SECTION 2 で実証済みの可否を 0/1 集計）
--   ③ データ鮮度  : 事実テーブル（SECTION 3 で実証済みの特性を秒数 / -1=手動）
--   ④ リネージ    : 実機（SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES）
--   ⑤ コスト      : 実機（SECTION 5 の src_large に対する bytes_scanned 合計）
--   ⑥ 自動化      : 事実テーブル（SECTION 6 で実証済みの追加設定数）
-- ─────────────────────────────────────────────────────────────

WITH
-- ── 軸①: 実機の query_text 文字数を取得（直近の代表クエリ）
metric_writing AS (
    SELECT 'INSERT（マルチテーブル）' AS method,
           (SELECT LENGTH(query_text)
            FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
            WHERE query_text ILIKE 'INSERT ALL%t1_mi%'
              AND query_text NOT ILIKE '%src_large%'  -- SECTION 5 の大量データ版を除外（小データ版を計測）
            ORDER BY start_time DESC LIMIT 1) AS sql_chars
    UNION ALL
    SELECT '個別 INSERT',
           (SELECT SUM(LENGTH(query_text))
            FROM (
                SELECT query_text
                FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
                WHERE (query_text ILIKE 'INSERT INTO t1_ind%'
                    OR query_text ILIKE 'INSERT INTO t2_ind%')
                  AND query_text NOT ILIKE '%src_large%'  -- SECTION 5 の大量データ版を除外
                ORDER BY start_time DESC
                LIMIT 2
            ))
    UNION ALL
    SELECT 'Dynamic Tables',
           (SELECT SUM(LENGTH(query_text))
            FROM (
                SELECT query_text
                FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
                -- t1_dt の直後は改行のため末尾スペース指定では一致しない。
                -- t1_dt% で拾い、src_large（=_dt_large）版を NOT ILIKE で除外する。
                WHERE (query_text ILIKE 'CREATE OR REPLACE DYNAMIC TABLE t1_dt%'
                    OR query_text ILIKE 'CREATE OR REPLACE DYNAMIC TABLE t2_dt%')
                  AND query_text NOT ILIKE '%src_large%'
                ORDER BY start_time DESC
                LIMIT 2
            ))
    UNION ALL
    -- dbt は Snowflake から見える展開後 SQL ではなく、人が書いた Jinja 行数で評価
    -- （models/t1.sql + t2.sql + sources.yml + schema.yml + dbt_project.yml の合計目安）
    SELECT 'dbt', 1200  -- 5 ファイル合計の概算（01 の Phase C 構成から）
),
-- ── 軸②: 機能の対応可否（複数テーブル / 原子性 / upsert の 0/1 を合算）
metric_features AS (
    SELECT * FROM VALUES
        ('INSERT（マルチテーブル）', 1, 1, 0),  -- 複数◎ / 原子◎ / upsert×
        ('個別 INSERT',            0, 0, 0),    -- 単一文では複数不可・TX が必要
        ('Dynamic Tables',         1, 1, 1),    -- 全機能対応（DT は upsert 相当の追従可）
        ('dbt',                    1, 0, 1)     -- 複数モデル可・TX 不可・upsert は incremental で対応
    AS t(method, multi_table, atomic, upsert)
),
-- ── 軸③: データ鮮度（反映までの目安秒数、-1 = 手動再実行が必要）
metric_freshness AS (
    SELECT * FROM VALUES
        ('INSERT（マルチテーブル）', -1),   -- 手動再実行が必要
        ('個別 INSERT',            -1),     -- 同上
        ('Dynamic Tables',         60),     -- TARGET_LAG=1min
        ('dbt',                    300)     -- 仮定値: 5 分間隔の scheduler 想定
    AS t(method, freshness_sec)
),
-- ── 軸④: 実機の依存関係記録の有無（src を依存元として持つ件数）
metric_lineage AS (
    SELECT 'INSERT（マルチテーブル）' AS method,
           (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
            WHERE referencing_object_name = 'T1_MI' AND referenced_object_name = 'SRC') AS lineage_recorded
    UNION ALL
    SELECT '個別 INSERT',
           (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
            WHERE referencing_object_name = 'T1_IND' AND referenced_object_name = 'SRC')
    UNION ALL
    SELECT 'Dynamic Tables',
           (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
            WHERE referencing_object_name = 'T1_DT' AND referenced_object_name = 'SRC')
    UNION ALL
    SELECT 'dbt',
           (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
            WHERE referencing_object_name = 'T1_DBT' AND referenced_object_name = 'SRC')
),
-- ── 軸⑤: 実機の bytes_scanned 合計（src_large 約 110 万行に対する INSERT 履歴）
metric_cost AS (
    SELECT * FROM (
        SELECT
            CASE
                WHEN query_text ILIKE 'INSERT ALL%' THEN 'INSERT（マルチテーブル）'
                WHEN query_text ILIKE 'INSERT INTO t1_ind%' OR query_text ILIKE 'INSERT INTO t2_ind%' THEN '個別 INSERT'
                WHEN query_text ILIKE 'CREATE OR REPLACE DYNAMIC TABLE t1_dt_large%' OR query_text ILIKE 'CREATE OR REPLACE DYNAMIC TABLE t2_dt_large%' THEN 'Dynamic Tables'
            END AS method,
            bytes_scanned
        FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
        WHERE query_text ILIKE '%src_large%'
    )
    WHERE method IS NOT NULL
), metric_cost_agg AS (
    SELECT method, SUM(bytes_scanned) AS bytes_scanned
    FROM metric_cost
    GROUP BY method
    UNION ALL
    SELECT 'dbt', NULL  -- dbt は Workspaces 実行のためセッション QUERY_HISTORY で取れないことがある
),
-- ── 軸⑥: 自動化に必要な追加設定の要素数
metric_automation AS (
    SELECT * FROM VALUES
        ('INSERT（マルチテーブル）', 3),  -- WAREHOUSE / SCHEDULE / RESUME の 3 設定が必要
        ('個別 INSERT',            3),    -- 同上 + スクリプトブロック
        ('Dynamic Tables',         0),    -- CREATE 時の TARGET_LAG のみで自動化完了
        ('dbt',                    1)     -- Snowflake Workspaces のスケジュール設定が必要
    AS t(method, auto_setup_count)
)
SELECT
    w.method                                  AS "手法",
    w.sql_chars                               AS "①記述量(文字)",
    f.multi_table || '/' || f.atomic || '/' || f.upsert AS "②機能(複/原/Up)",
    CASE WHEN fr.freshness_sec = -1 THEN '手動' ELSE fr.freshness_sec::VARCHAR || '秒' END AS "③鮮度",
    l.lineage_recorded                        AS "④リネージ(0/1)",
    c.bytes_scanned                           AS "⑤bytes_scanned",
    a.auto_setup_count                        AS "⑥自動化(設定数)"
FROM metric_writing w
LEFT JOIN metric_features  f  ON w.method = f.method
LEFT JOIN metric_freshness fr ON w.method = fr.method
LEFT JOIN metric_lineage   l  ON w.method = l.method
LEFT JOIN metric_cost_agg  c  ON w.method = c.method
LEFT JOIN metric_automation a ON w.method = a.method
ORDER BY
    CASE w.method
        WHEN 'INSERT（マルチテーブル）' THEN 1
        WHEN '個別 INSERT'              THEN 2
        WHEN 'Dynamic Tables'           THEN 3
        WHEN 'dbt'                      THEN 4
    END;
-- ↑ この 1 表が「実機検証から定量的に出した 4 手法 × 6 軸の比較表」
-- ↑ 凡例の◎○△×は上のテキスト罫線マトリクス（事前評定）を参照


-- ============================================================
-- SECTION 9: クリーンアップ（コスト垂れ流し防止）★必ず実行
-- ------------------------------------------------------------
-- ▶ なぜ必要か:
-- ・Dynamic Tables は CREATE 時点から TARGET_LAG='1 minute' に従って
--   自動リフレッシュが走り続ける（差分がなくても WH 起動チェックが入る）
-- ・SECTION 5 で作った src_large（約 110 万行）と t1_dt_large / t2_dt_large は
--   ストレージ + リフレッシュコストが特に大きい
-- ・トライアル $400 クレジットを知らない間に消費してしまうため、
--   登壇終了後に必ず以下のいずれかを実行する
--
-- ▶ 2 つの選択肢:
-- ・選択肢 A（推奨）: DROP で完全削除
--    → 検証後にもう使わないなら一番安全
-- ・選択肢 B: SUSPEND（停止）のみ
--    → 後日再利用する可能性があるとき。SCHEDULING_STATE='SUSPENDED' で
--      リフレッシュが止まりコンピュート消費がゼロになる
-- ============================================================

-- ── 選択肢 A: 完全削除（推奨） ─────────────────────────────

-- 【最優先】SECTION 5 の大量データ系（ストレージ + リフレッシュコスト大）
DROP DYNAMIC TABLE IF EXISTS t1_dt_large;
DROP DYNAMIC TABLE IF EXISTS t2_dt_large;
DROP TABLE IF EXISTS src_large;

-- 高速ウェアハウス compute_wh_perf は 01_準備フェーズ.sql のフェーズ D で
-- 事前作成した想定。AUTO_SUSPEND=60 秒で自動停止するため、アイドル中の
-- コンピュートコストは発生しない（＝残しておいてもコスト垂れ流しにならない）。
-- → 通常は残してよい（次回の登壇でそのまま再利用できる）。念のため COMPUTE_WH に戻す。
USE WAREHOUSE COMPUTE_WH;

-- 環境を完全に消したい場合のみ、下記のコメントを外して DROP する。
-- ※ 使用中の WH は DROP できないため、先に上で COMPUTE_WH へ切り替えてある。
-- ※ DROP した場合、再演時は 01 のフェーズ D を再実行して作り直すこと。
-- DROP WAREHOUSE IF EXISTS compute_wh_perf;

-- 通常 DT を DROP（リフレッシュも停止し、テーブル実体も消える）
DROP DYNAMIC TABLE IF EXISTS t1_dt;
DROP DYNAMIC TABLE IF EXISTS t2_dt;

-- INSERT（マルチテーブル）/ 個別 INSERT 用テーブル
DROP TABLE IF EXISTS t1_mi;
DROP TABLE IF EXISTS t2_mi;
DROP TABLE IF EXISTS t1_ind;
DROP TABLE IF EXISTS t2_ind;

-- dbt 由来テーブル（Workspaces で再実行すれば再作成される）
DROP TABLE IF EXISTS t1_dbt;
DROP TABLE IF EXISTS t2_dbt;

-- TASK は本 SQL の SECTION 6 末尾で既に DROP 済みだが、念のため再確認
DROP TASK IF EXISTS task_refresh_mi;

-- ▶ クリーンアップ後の確認: 上記オブジェクトが消えていること
-- 想定: 0 件
SELECT COUNT(*) AS remaining_objects
FROM information_schema.tables
WHERE table_schema = 'WEEK101'
  AND (table_name LIKE '%_MI' OR
        table_name LIKE '%_IND' OR
        table_name LIKE '%_DT' OR
        table_name LIKE '%_DT_LARGE' OR
        table_name LIKE '%_DBT' OR
        table_name = 'SRC_LARGE');

-- ▶ 高速ウェアハウスの状態確認
-- 想定: 残す運用なら 1 件で state=SUSPENDED（停止＝コスト 0）。
--       上の DROP を実行した場合は 0 件。
SHOW WAREHOUSES LIKE 'COMPUTE_WH_PERF';


-- ── 選択肢 B: SUSPEND のみ（後日再利用する場合） ───────────
-- ※ 上の DROP を実行した後に B を実行するとエラーになる。どちらか一方のみ。
-- ALTER DYNAMIC TABLE t1_dt SUSPEND;
-- ALTER DYNAMIC TABLE t2_dt SUSPEND;
-- ALTER DYNAMIC TABLE t1_dt_large SUSPEND;
-- ALTER DYNAMIC TABLE t2_dt_large SUSPEND;
--
-- ▶ SUSPEND 後の状態確認（scheduling_state='SUSPENDED' になっていれば OK）
-- SHOW DYNAMIC TABLES LIKE 'T%_DT%';
-- SELECT "name", "scheduling_state", "target_lag"
-- FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
