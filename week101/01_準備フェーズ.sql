-- ============================================================
-- Frosty Friday Week 101 - 準備フェーズ
-- テーマ: 条件付き INSERT（マルチテーブル）（海賊データ）
-- URL: https://frostyfriday.org/blog/2024/07/12/week-101-easy/
--
-- 本ファイルは下記 3 フェーズで構成される：
-- フェーズ A: 検証用ロール作成（初回 1 回のみ、ACCOUNTADMIN を使用）
-- フェーズ B: 検証環境セットアップ（毎回実行可、FROSTY_FRIDAY_ROLE を使用）
-- フェーズ C: dbt Projects on Snowflake の準備（別解比較で dbt を使う場合のみ）
--
-- 運用方針:
-- ・02_実践フェーズ_基礎編.sql 以降は FROSTY_FRIDAY_ROLE で実行する。
-- ・フェーズ A は初回 1 回のみ必要。2 回目以降はスキップ可能。
-- ・フェーズ C は dbt を実演する場合のみ実施（実演しなければスキップ可）。
-- ・SYSADMIN ロールへの切替は運用フェーズでは行わない（階層化登録のみ）。
-- ・ACCOUNTADMIN ロールはフェーズ A の権限付与でのみ最小限使用する。
-- 理由: CREATE DATABASE / EXECUTE TASK / IMPORTED PRIVILEGES の
-- ACCOUNT レベル権限付与は Snowflake の権限モデル上
-- ACCOUNTADMIN でしか GRANT できないため。
-- ============================================================


-- ============================================================
-- フェーズ A: 検証用ロール FROSTY_FRIDAY_ROLE の作成
-- 初回 1 回のみ実行。2 回目以降は不要（フェーズ B から再開可）。
-- 実行ロール: ACCOUNTADMIN（このフェーズ限り）
-- ============================================================

-- ------------------------------------------------------------
-- A-1: 検証用ロールの作成（USERADMIN で実行）
-- USERADMIN はロール作成・削除・付与の専用権限を持つ
-- ------------------------------------------------------------
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS FROSTY_FRIDAY_ROLE
    COMMENT = 'Frosty Friday Live Challenge 検証用ロール（SYSADMIN 配下）';

-- ------------------------------------------------------------
-- A-2: SYSADMIN 配下にロールを階層化（SECURITYADMIN で実行）
-- SYSADMIN ユーザーが FROSTY_FRIDAY_ROLE の権限を継承可能にする
-- ※ 運用では SYSADMIN にスイッチせず、FROSTY_FRIDAY_ROLE 1 本で動かす
-- ------------------------------------------------------------
USE ROLE SECURITYADMIN;

GRANT ROLE FROSTY_FRIDAY_ROLE TO ROLE SYSADMIN;

-- ------------------------------------------------------------
-- A-3: ユーザーへのロール付与（SECURITYADMIN で実行）
-- ユーザー名は Snowsight 右下のプロフィール、または下記で確認可能:
-- SELECT CURRENT_USER();
-- ------------------------------------------------------------
GRANT ROLE FROSTY_FRIDAY_ROLE TO USER TSUNODA;

-- ------------------------------------------------------------
-- A-4: アカウントレベル権限の付与（ACCOUNTADMIN で実行）
-- ACCOUNTADMIN を使うのはこのフェーズだけ。以降は不要。
-- ------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

-- A-4-1. データベース作成権限（frosty_friday DB を作るため）
GRANT CREATE DATABASE ON ACCOUNT TO ROLE FROSTY_FRIDAY_ROLE;

-- A-4-2. ウェアハウス使用権限
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE FROSTY_FRIDAY_ROLE;

-- A-4-3. ACCOUNT_USAGE 参照権限
-- 応用編 セクション9 と別解比較 セクション4 で OBJECT_DEPENDENCIES 等を参照する
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE FROSTY_FRIDAY_ROLE;

-- A-4-4. TASK 実行権限（別解比較 セクション6 で TASK を作成・実行する）
GRANT EXECUTE TASK ON ACCOUNT TO ROLE FROSTY_FRIDAY_ROLE;

-- A-4-5. ウェアハウス作成権限（このファイルのフェーズ D で大量データ検証用の
--        高速ウェアハウス compute_wh_perf を事前作成するため）
-- ※ 大量データ（約 110 万行）の検証を登壇内で 1〜1.5 分に収めるため、
--   既定の COMPUTE_WH とは別に大サイズの WH を登壇前に作っておく。
--   作成したロールが OWNERSHIP を得るので、USE / 変更 / DROP も同ロールで可能。
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE FROSTY_FRIDAY_ROLE;

-- ------------------------------------------------------------
-- A-5: 付与権限の確認
-- 期待: USAGE on COMPUTE_WH / EXECUTE TASK / IMPORTED PRIVILEGES /
--       CREATE DATABASE / CREATE WAREHOUSE の 5 件以上
-- ------------------------------------------------------------
USE ROLE FROSTY_FRIDAY_ROLE;

SHOW GRANTS TO ROLE FROSTY_FRIDAY_ROLE;


-- ============================================================
-- フェーズ B: 検証環境セットアップ
-- 毎回実行可能（CREATE OR REPLACE で冪等）。
-- 実行ロール: FROSTY_FRIDAY_ROLE
-- ============================================================

-- ------------------------------------------------------------
-- B-1: 実行ロール・ウェアハウスの切替
-- ------------------------------------------------------------
USE ROLE FROSTY_FRIDAY_ROLE;
USE WAREHOUSE COMPUTE_WH;

-- ------------------------------------------------------------
-- B-2: データベース・スキーマのセットアップ
-- ------------------------------------------------------------
CREATE OR REPLACE DATABASE frosty_friday;
CREATE OR REPLACE SCHEMA frosty_friday.week101;

USE DATABASE frosty_friday;
USE SCHEMA week101;

-- ------------------------------------------------------------
-- B-3: 宛先テーブル t1, t2 の作成（チャレンジ提供）
-- t1, t2 の 2 テーブルに src のデータを振り分けるのが本お題
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE t1 (
    pirate_name STRING,
    booty_amount NUMBER,
    rank STRING,
    ship_name STRING
);

CREATE OR REPLACE TABLE t2 (
    pirate_name STRING,
    booty_amount NUMBER,
    rank STRING,
    ship_name STRING
);

-- ------------------------------------------------------------
-- B-4: ソーステーブル src の作成・データ投入（チャレンジ提供）
-- src は INSERT ALL の元データになる
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- B-5: src データ確認
-- ------------------------------------------------------------
SELECT * FROM src ORDER BY booty_amount DESC;

-- ------------------------------------------------------------
-- B-6: 振り分け想定の可視化（CASE で予告）
-- INSERT ALL 実行後の t1 / t2 がこの to_t1 / to_t2 の Y と一致するはず
-- お題ルールを CASE で先に視覚化することで、実行結果を予測してから INSERT する
-- ------------------------------------------------------------
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
-- 想定: to_t1=Y は 3 件 (Henry Morgan / Jack Sparrow / Stede Bonnet)
-- 想定: to_t2=Y は 8 件 (Stede Bonnet を含む残り全員)


-- ============================================================
-- フェーズ C: dbt Projects on Snowflake の準備
-- 別解比較（04）で dbt を比較対象として使う場合のみ実施。
-- 実演しない場合はこのフェーズは丸ごとスキップして問題ない。
--
-- dbt Projects on Snowflake は Snowflake 標準機能（2025 年 11 月 GA）。
-- 外部 CLI / dbt Cloud は不要、Snowsight Workspaces 内で完結する。
--
-- 実行ロール: FROSTY_FRIDAY_ROLE
-- ============================================================

-- ------------------------------------------------------------
-- C-1: dbt 実行に必要な権限の確認
-- FROSTY_FRIDAY_ROLE で dbt を動かすため、以下の権限が必要：
-- ・USAGE on WAREHOUSE COMPUTE_WH （フェーズ A の A-4-2 で付与済み）
-- ・USAGE on DATABASE frosty_friday （フェーズ B で自分が CREATE → OWNERSHIP で自動取得）
-- ・USAGE / CREATE TABLE on SCHEMA week101（同上）
-- ------------------------------------------------------------
SHOW GRANTS TO ROLE FROSTY_FRIDAY_ROLE;

-- ------------------------------------------------------------
-- C-2: dbt プロジェクト構成ファイル一覧
-- 下記 5 ファイルを Snowsight Workspaces 内に配置する。
-- （SQL では作成できないため Snowsight UI で操作）
-- ------------------------------------------------------------
/*
─────────────────────────────────────────────────────────
[dbt_project.yml]
─────────────────────────────────────────────────────────
※ Snowsight Workspaces で dbt project を新規作成すると自動生成される。
※ name / profile はワークスペース内のプロジェクト名（例: frosty_friday_dbt）が入る。
※ 自動生成テンプレートのまま使用可。
   各モデル側で {{ config(materialized='table') }} を指定するため、
   project.yml の materialized は view のままで上書きされる。

─────────────────────────────────────────────────────────
[models/sources.yml]
─────────────────────────────────────────────────────────
version: 2

sources:
  - name: week101
    database: frosty_friday
    schema: week101
    tables:
      - name: src
        description: Frosty Friday Week 101 のお題ソーステーブル（海賊データ 10 件）

─────────────────────────────────────────────────────────
[models/t1.sql] → t1_dbt として出力
─────────────────────────────────────────────────────────
{{ config(materialized='table', alias='t1_dbt') }}

SELECT
    pirate_name,
    booty_amount,
    rank,
    ship_name
FROM {{ source('week101', 'src') }}
WHERE booty_amount > 700 -- 条件A: t1 のみ
   OR booty_amount < 100 -- 条件C: t1 と t2 の両方（t1 側）

─────────────────────────────────────────────────────────
[models/t2.sql] → t2_dbt として出力
─────────────────────────────────────────────────────────
{{ config(materialized='table', alias='t2_dbt') }}

SELECT
    pirate_name,
    booty_amount,
    rank,
    ship_name
FROM {{ source('week101', 'src') }}
WHERE rank = 'First Mate' -- 条件B
   OR booty_amount < 100 -- 条件C（t2 側）
   OR (booty_amount BETWEEN 100 AND 700 AND rank != 'First Mate') -- ELSE

─────────────────────────────────────────────────────────
[models/schema.yml] → テスト定義
─────────────────────────────────────────────────────────
version: 2

models:
  - name: t1
    description: 条件A（booty>700）または条件C（booty<100）の海賊
    columns:
      - name: pirate_name
        description: 海賊名（NULL 禁止）
        tests:
          - not_null
      - name: booty_amount
        tests:
          - not_null
  - name: t2
    description: 条件B（First Mate）/ 条件C（booty<100）/ ELSE の海賊
    columns:
      - name: pirate_name
        tests:
          - not_null
      - name: booty_amount
        tests:
          - not_null

※ Jinja2 構文（{{ config(...) }}、{{ source(...) }}）内のシングルクォートは
　 Python / Jinja2 の文字列リテラルなので残す（YAML のクォートとは別物）。
*/

-- ------------------------------------------------------------
-- C-3: Snowsight Workspaces で dbt プロジェクトを作成する手順
-- （Snowsight UI 操作、SQL では実行不可）
-- ------------------------------------------------------------
/*
  1. Snowsight 左サイドバー → Projects → Workspaces を開く
  2. 「+ Add」 → 「New Workspace」または既存 Git リポジトリから作成
  3. C-2 の 5 ファイルを配置（dbt_project.yml は直下、その他は models/ 配下）
  4. Workspace の Connection 設定で以下を指定：
       ・Role: FROSTY_FRIDAY_ROLE
       ・Warehouse: COMPUTE_WH
       ・Database: frosty_friday
       ・Schema: week101
  5. Workspace UI 右上の「Run all」をクリック（= dbt run 相当）
  6. 続けて「Test」をクリック（= dbt test 相当、not_null テストが実行される）
  7. 「Lineage」タブで src → t1 / t2 の依存 DAG が表示されることを確認
*/

-- ------------------------------------------------------------
-- C-4: dbt 実行後の結果確認（C-3 の Run all を実行した後で実施）
-- ------------------------------------------------------------

-- ▶ C-4-1: dbt が作成したテーブルが存在するか確認
-- 想定: T1_DBT と T2_DBT の 2 件が表示される
SHOW TABLES LIKE '%_DBT' IN SCHEMA frosty_friday.week101;

-- ▶ C-4-2: 件数確認
-- 想定: t1_dbt=3（条件A の 2 件 + 条件C の 1 件）/ t2_dbt=8（条件B + ELSE + 条件C）
SELECT 't1_dbt' AS tbl, COUNT(*) AS cnt FROM t1_dbt
UNION ALL
SELECT 't2_dbt', COUNT(*) FROM t2_dbt;

-- ▶ C-4-3: 全件確認（基礎編の t1 / t2 と同じ振り分け結果になっているか）
SELECT 't1_dbt' AS tbl, pirate_name, booty_amount, rank, ship_name
FROM t1_dbt
ORDER BY booty_amount DESC;

SELECT 't2_dbt' AS tbl, pirate_name, booty_amount, rank, ship_name
FROM t2_dbt
ORDER BY booty_amount DESC;


-- ============================================================
-- フェーズ D: 大量データ検証用ウェアハウスの事前作成
-- 別解比較（04）の SECTION 5（コスト検証・約 110 万行）を登壇内で高速に
-- 実行するため、大きいサイズのウェアハウス compute_wh_perf を登壇前に作っておく。
-- 登壇時は 04 の SECTION 5 でこの WH に USE で切り替えて使うだけにする。
--
-- ・別解比較（04）のコスト検証を実演する場合のみ実施（しない場合はスキップ可）。
-- ・このフェーズ D は登壇前のリハーサル時に済ませておく前提。
-- 実行ロール: FROSTY_FRIDAY_ROLE（A-4-5 で CREATE WAREHOUSE 権限を付与済み）
-- ============================================================
USE ROLE FROSTY_FRIDAY_ROLE;

-- ------------------------------------------------------------
-- D-1: 高速ウェアハウスの作成
-- ------------------------------------------------------------
-- ★【要調整】WAREHOUSE_SIZE は実機での実行時間を見て決める。
--   目安: 04 SECTION 5 の execution_sec が 90 秒（1 分 30 秒）を超えるなら 1 段上げる
--   （XSMALL→SMALL→MEDIUM→LARGE…）。十分速ければ下げてコストを削減する。
--   初期値は MEDIUM。登壇前のリハーサルで実測して確定すること。
-- ▶ コスト注意: AUTO_SUSPEND=60 秒 / INITIALLY_SUSPENDED=TRUE のため、
--   「作成しただけ」「アイドル中」はコンピュートコストが発生しない（使った分だけ課金）。
--   よって登壇前に作っておいても、実際に使うまでコストはかからない。
CREATE WAREHOUSE IF NOT EXISTS compute_wh_perf
    WAREHOUSE_SIZE = 'MEDIUM'        -- ★【要調整】リハーサルで実測後に確定（XSMALL〜LARGE）
    AUTO_SUSPEND = 60                -- アイドル 60 秒で自動停止
    AUTO_RESUME = TRUE               -- クエリ実行時に自動再開
    INITIALLY_SUSPENDED = TRUE       -- 作成直後は停止状態（最初のクエリで起動）
    COMMENT = 'Week101 別解比較 SECTION5 大量データ検証専用（登壇前に事前作成）';

-- ------------------------------------------------------------
-- D-2: 作成確認
-- 想定: compute_wh_perf が 1 件、state=SUSPENDED（停止＝コスト 0）で存在
-- ------------------------------------------------------------
SHOW WAREHOUSES LIKE 'COMPUTE_WH_PERF';
