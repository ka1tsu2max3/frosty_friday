-- ============================================================
-- Frosty Friday Week 101 - 実践フェーズ（応用編）
-- INSERT（マルチテーブル）を軸にした付加価値デモ集
--
-- 実行前提: 01_準備フェーズ.sql と 02_実践フェーズ_基礎編.sql が完了していること
-- 各セクションは上から順に実行すること
-- 実行ロール: FROSTY_FRIDAY_ROLE
-- ============================================================

USE ROLE FROSTY_FRIDAY_ROLE;
USE DATABASE frosty_friday;
USE SCHEMA week101;


-- ============================================================
-- SECTION 1: 無条件 INSERT（マルチテーブル）— 本体 + 監査ログ同時書き込み
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- WHEN 句なしの INSERT ALL で src の全 10 件を
-- pirates_main（本体）と pirates_audit（監査ログ）の両方に同時書き込みし、
-- 2 テーブルが必ず同件数（10 件）で揃うことを確認する。
-- ------------------------------------------------------------
-- 内容: INSERT ALL は「振り分け」だけでなく「複数テーブルへの同時書き込み」も可能
-- ▶ ポイント（テクニック面）:
-- ・WHEN 句なし → 全行が INTO 指定先の全テーブルに入る（複製パターン）
-- ・1 SQL 文なので原子性が保証される（同件数で確実に揃う）
-- ▶ ポイント（実務面）:
-- ・本体テーブルへの書き込みと監査ログを 1 文で確実に同期できる
-- → 「本体に入ってログが漏れる事故」が構造的に起きない
-- ・同じ仕組みでバックアップ・ステージング・テスト環境への
-- 同時書き込みにも応用可
-- ============================================================

CREATE OR REPLACE TABLE pirates_main (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE pirates_audit (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR,
    inserted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    operation_type VARCHAR
);

-- ▶ 実行前確認: 本体と監査ログが空であることを確認
-- 想定: pirates_main=0 / pirates_audit=0
SELECT 'pirates_main' AS tbl, COUNT(*) AS cnt FROM pirates_main
UNION ALL
SELECT 'pirates_audit', COUNT(*) FROM pirates_audit;

-- 無条件 INSERT ALL（WHEN 句なし）で本体テーブルと監査ログに同時書き込み
INSERT ALL
    INTO pirates_main (pirate_name, booty_amount, rank, ship_name)
    INTO pirates_audit (pirate_name, booty_amount, rank, ship_name, operation_type)
        VALUES (pirate_name, booty_amount, rank, ship_name, 'INSERT')
SELECT * FROM src;

-- ▶ 実行後の結果確認
-- 想定: pirates_main=10 / pirates_audit=10（本体と監査が同件数で一致）
SELECT 'pirates_main' AS tbl, COUNT(*) AS cnt FROM pirates_main
UNION ALL
SELECT 'pirates_audit', COUNT(*) FROM pirates_audit;

-- pirates_main の全件確認
SELECT pirate_name, booty_amount, rank, ship_name
FROM pirates_main
ORDER BY booty_amount DESC;

-- pirates_audit のサンプル（直近 5 件、inserted_at と operation_type も確認）
SELECT * FROM pirates_audit LIMIT 5;

-- ▶ こういう場面で使う:
-- 本番テーブルへの書き込みと同時に監査ログ / バックアップを残したいとき。
-- 本体とログが必ずセットで揃うことを「データの仕組み」で保証したい場合。


-- ============================================================
-- SECTION 2: INSERT ALL と INSERT FIRST の使い分け
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- INSERT FIRST だと条件 C の行（Stede Bonnet）が
-- 片方のテーブルから漏れることを INSERT ALL の結果と比較して確認する。
-- ------------------------------------------------------------
-- 内容: 「同じ行を複数テーブルに入れる」場合は INSERT FIRST では
-- 実現できないことをデモで示す
-- ▶ ポイント:
-- ・INSERT FIRST は最初に一致した条件で止まる
-- → 「両方に入れたい行」があると片方が漏れるバグになる
-- ・今回の Stede Bonnet（booty=50）がその典型例
-- ・INSERT ALL / FIRST の選択ミスは実行時エラーにならず
-- データ不足として気づきにくい点を強調する
-- ============================================================

CREATE OR REPLACE TABLE t1_first (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE t2_first (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);

-- ▶ 実行前確認: ターゲットテーブルが空であることを確認
-- 想定: t1_first=0 / t2_first=0
SELECT 't1_first' AS tbl, COUNT(*) AS cnt FROM t1_first
UNION ALL
SELECT 't2_first', COUNT(*) FROM t2_first;

-- INSERT FIRST: booty < 100 の条件が t1_first で止まり t2_first に入らない（バグ相当）
INSERT FIRST
    WHEN booty_amount > 700 THEN INTO t1_first
    WHEN rank = 'First Mate' THEN INTO t2_first
    WHEN booty_amount < 100 THEN INTO t1_first -- ← ここで止まる（t2_firstへは行かない）
    ELSE INTO t2_first
SELECT * FROM src;

-- ▶ 実行後の結果確認【3 段構え】

-- ① 件数比較: INSERT FIRST と INSERT ALL の差を一目で
-- 想定: FIRST → t1_first=3 / t2_first=7（Stede Bonnet が漏れる）
-- ALL → t1=3 / t2=8（Stede Bonnet が両方に入る）
SELECT 'INSERT FIRST → t1' AS result, COUNT(*) AS cnt FROM t1_first
UNION ALL SELECT 'INSERT FIRST → t2', COUNT(*) FROM t2_first
UNION ALL SELECT 'INSERT ALL → t1', COUNT(*) FROM t1
UNION ALL SELECT 'INSERT ALL → t2', COUNT(*) FROM t2;

-- ② 全件確認: INSERT FIRST の t1_first / t2_first に入っているレコード
SELECT 't1_first' AS tbl, pirate_name, booty_amount, rank
FROM t1_first
ORDER BY booty_amount DESC;

SELECT 't2_first' AS tbl, pirate_name, booty_amount, rank
FROM t2_first
ORDER BY booty_amount DESC;

-- ③ 差分フォーカス: 条件 C（booty<100）の Stede Bonnet が両方に入っているか
-- 想定: FIRST → t1_first に 1 件、t2_first に 0 件（漏れ）
-- ALL → t1 に 1 件、t2 に 1 件（正しい）
SELECT 'INSERT FIRST → t1' AS result, pirate_name, booty_amount FROM t1_first WHERE booty_amount < 100
UNION ALL SELECT 'INSERT FIRST → t2', pirate_name, booty_amount FROM t2_first WHERE booty_amount < 100
UNION ALL SELECT 'INSERT ALL → t1', pirate_name, booty_amount FROM t1 WHERE booty_amount < 100
UNION ALL SELECT 'INSERT ALL → t2', pirate_name, booty_amount FROM t2 WHERE booty_amount < 100;

-- ▶ こういう場面で使う:
-- 振り分けロジックを設計するとき。「同じ行を複数テーブルに入れたい要件があるか？」のチェック観点。


-- ============================================================
-- SECTION 3: CTE との組み合わせ
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- CTE で事前計算した RANK 値を WHEN 条件に使い、
-- 戦利品 TOP3 を pirates_elite / それ以外を pirates_normal に振り分けできることを確認する。
-- ------------------------------------------------------------
-- 内容: ウィンドウ関数などで計算した値を振り分け条件に使う
-- ▶ ポイント:
-- ・INSERT ALL の条件は「列の値そのまま」だけでなく
-- CTE で事前計算した値でも使える
-- ・ランク・パーセンタイル・移動平均など集計結果での
-- ルーティングが1クエリで完結する
-- ・複数のSELECTを書かなくてよいのでコードが簡潔になる
-- ============================================================

CREATE OR REPLACE TABLE pirates_elite (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR,
    booty_rank NUMBER
);
CREATE OR REPLACE TABLE pirates_normal (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR,
    booty_rank NUMBER
);

-- ▶ 実行前確認: ターゲットテーブルが空であることを確認
-- 想定: pirates_elite=0 / pirates_normal=0
SELECT 'pirates_elite' AS tbl, COUNT(*) AS cnt FROM pirates_elite
UNION ALL
SELECT 'pirates_normal', COUNT(*) FROM pirates_normal;

-- CTE でランク計算 → WHEN でランク条件を使って振り分け
INSERT ALL
    WHEN booty_rank <= 3 THEN INTO pirates_elite -- 戦利品 TOP3 → エリートテーブル
    ELSE INTO pirates_normal -- それ以外 → 一般テーブル
WITH ranked AS (
    SELECT *,
           RANK() OVER (ORDER BY booty_amount DESC) AS booty_rank
    FROM src
)
SELECT * FROM ranked;

-- ▶ 実行後の結果確認
-- 想定: pirates_elite=3（TOP3） / pirates_normal=7（残り）
SELECT 'pirates_elite' AS tbl, COUNT(*) AS cnt FROM pirates_elite
UNION ALL
SELECT 'pirates_normal', COUNT(*) FROM pirates_normal;

-- 全件確認: TOP3 と一般の中身
-- ※ UNION ALL の各 SELECT に ORDER BY は書けない → 最後に 1 回だけ書く
SELECT 'elite' AS tier, pirate_name, booty_amount, booty_rank FROM pirates_elite
UNION ALL
SELECT 'normal', pirate_name, booty_amount, booty_rank FROM pirates_normal
ORDER BY tier, booty_rank;

-- ▶ こういう場面で使う:
-- ランク / パーセンタイル / 移動平均などの集計結果を基に振り分けたいとき。


-- ============================================================
-- SECTION 4: INSERT（マルチテーブル）でメダリオン Bronze → Silver / Quarantine 昇格
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- NULL を含む生データ（Bronze 層 12 件）を、INSERT（マルチテーブル）の WHEN 句で
-- 品質チェックして Silver 層（10 件）と Quarantine 層（2 件）に振り分けることを確認する。
-- ------------------------------------------------------------
-- 内容: INSERT（マルチテーブル）の WHEN 句に品質チェックを組み込み、Silver / Quarantine に振り分け
-- ▶ ポイント（テクニック面）:
-- ・NULL に対する比較演算（> や <）は常に false → 何にもマッチせず ELSE に流れる罠
-- ・WHEN pirate_name IS NULL THEN INTO quarantine_pirates のように
-- 明示的に NULL 検知の WHEN を組み込むことで罠を回避
-- ・reject_reason カラムで「なぜ弾かれたか」のトレーサビリティ確保
-- ▶ ポイント（実務面）:
-- ・モダンデータ基盤のメダリオンアーキテクチャの Bronze → Silver 昇格処理を
-- SQL 単体で実装できる（ETL ツール不要）
-- ・品質ルール（NULL / 負値 / 異常値）を WHEN 句に集約 → 追加・変更が容易
-- ============================================================

-- NULL を含むソースデータを用意（APIやファイル取り込み時に混入しうる状況を再現）
CREATE OR REPLACE TABLE src_with_null (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
INSERT INTO src_with_null SELECT * FROM src;
INSERT INTO src_with_null VALUES
    ('Unknown Pirate', NULL, 'Captain', 'Ghost Ship'), -- booty_amount が NULL
    (NULL, 200, 'First Mate', 'Mystery Ship'); -- pirate_name が NULL

-- Bronze 層: 生データ（NULL・異常値を含む可能性あり）
CREATE OR REPLACE TABLE bronze_pirates (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Silver 層: 品質チェック済みデータ
CREATE OR REPLACE TABLE silver_pirates (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR,
    validated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Quarantine 層: 品質 NG データ（調査・修正待ち）
CREATE OR REPLACE TABLE quarantine_pirates (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR,
    reject_reason VARCHAR,
    rejected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- ▶ 実行前確認: src_with_null の件数と Bronze / Silver / Quarantine が空であることを確認
-- 想定: src_with_null=12（src 10 件 + NULL 2 件）/ bronze=0 / silver=0 / quarantine_pirates=0
SELECT 'src_with_null' AS tbl, COUNT(*) AS cnt FROM src_with_null
UNION ALL SELECT 'bronze_pirates', COUNT(*) FROM bronze_pirates
UNION ALL SELECT 'silver_pirates', COUNT(*) FROM silver_pirates
UNION ALL SELECT 'quarantine_pirates', COUNT(*) FROM quarantine_pirates;

-- Bronze 層にデータをロード（NULL 混入データを含む生データとして格納）
INSERT INTO bronze_pirates (pirate_name, booty_amount, rank, ship_name)
SELECT * FROM src_with_null;

-- Bronze → Silver / Quarantine への昇格ルール
-- WHEN 句で品質チェック → NG なら quarantine（reject_reason 付き）、OK なら silver
-- ※ bronze_pirates は loaded_at を含む 5 列のため VALUES 句で 4 列を明示マッピング
INSERT ALL
    WHEN pirate_name IS NULL THEN
        INTO quarantine_pirates (pirate_name, booty_amount, rank, ship_name, reject_reason)
        VALUES (pirate_name, booty_amount, rank, ship_name, 'pirate_name is NULL')
    WHEN booty_amount IS NULL THEN
        INTO quarantine_pirates (pirate_name, booty_amount, rank, ship_name, reject_reason)
        VALUES (pirate_name, booty_amount, rank, ship_name, 'booty_amount is NULL')
    WHEN booty_amount < 0 THEN
        INTO quarantine_pirates (pirate_name, booty_amount, rank, ship_name, reject_reason)
        VALUES (pirate_name, booty_amount, rank, ship_name, 'booty_amount is negative')
    ELSE
        INTO silver_pirates (pirate_name, booty_amount, rank, ship_name)
        VALUES (pirate_name, booty_amount, rank, ship_name)
SELECT * FROM bronze_pirates;

-- ▶ 実行後の結果確認
-- 想定: bronze_pirates=12（src_with_null 全件）/ silver_pirates=10（品質OK）/ quarantine_pirates=2（NULL 含む 2 件）
SELECT 'bronze_pirates' AS layer, COUNT(*) AS cnt FROM bronze_pirates
UNION ALL SELECT 'silver_pirates', COUNT(*) FROM silver_pirates
UNION ALL SELECT 'quarantine_pirates', COUNT(*) FROM quarantine_pirates;

-- 何が・なぜ弾かれたかを全件確認（Quarantine 層、reject_reason 付き）
SELECT * FROM quarantine_pirates;

-- silver_pirates の全件確認（品質 OK のデータ）
SELECT pirate_name, booty_amount, rank, ship_name, validated_at
FROM silver_pirates
ORDER BY booty_amount DESC;

-- ▶ こういう場面で使う:
-- 外部取り込みデータの品質チェック + 隔離 + Silver 層昇格を 1 クエリで完結させたいとき。
-- メダリオンアーキテクチャの Bronze → Silver 昇格処理を SQL 単体で組みたい場合。


-- ============================================================
-- SECTION 5: INSERT（マルチテーブル）の原子性（all-or-nothing）
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- ① 正常パターン: INSERT（マルチテーブル）を src に対して実行 → 全 INTO が成功し、
-- t1_atomic / t2_atomic にデータが入ることを確認する。
-- ② エラーパターン: INSERT（マルチテーブル）を src_error に対して実行 → 1 行でも
-- 変換エラーが起きると INSERT（マルチテーブル）全体が失敗し、
-- t1_atomic_err / t2_atomic_err には 1 件も入らないことを確認する。
-- ------------------------------------------------------------
-- 内容: INSERT（マルチテーブル）は単一 SQL 文なのでステートメント原子性が組み込まれている
-- ▶ ポイント:
-- ・INSERT（マルチテーブル）は単一文 → 全成功 or 全失敗（all-or-nothing）
-- ・BEGIN / COMMIT で囲まなくても、文単体で原子性は保証される
-- ・個別 INSERT × N と比べた最大の違い:
-- INSERT INTO t1 ...; INSERT INTO t2 ...; で 2 文に分けると、
-- 1 文目が成功して 2 文目が失敗するとデータ不整合が起きる
-- → 不整合を防ぐためにわざわざ BEGIN / COMMIT で囲む必要が出てくる
-- ・INSERT（マルチテーブル）ならそもそも 1 文なので、囲む必要がない
-- ============================================================


-- ============================================================
-- ① 正常パターン: src (NUMBER 型) に対して INSERT（マルチテーブル）→ 全件成功
-- ============================================================

CREATE OR REPLACE TABLE t1_atomic (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE t2_atomic (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);

-- ▶ 実行前確認: ターゲットテーブルが空であることを確認
-- 想定: t1_atomic=0 / t2_atomic=0
SELECT 't1_atomic' AS tbl, COUNT(*) AS cnt FROM t1_atomic
UNION ALL
SELECT 't2_atomic', COUNT(*) FROM t2_atomic;

-- INSERT（マルチテーブル）実行（BEGIN / COMMIT で囲む必要なし）
INSERT ALL
    WHEN booty_amount > 700 THEN INTO t1_atomic
    WHEN rank = 'First Mate' THEN INTO t2_atomic
    WHEN booty_amount < 100 THEN INTO t1_atomic
    WHEN booty_amount < 100 THEN INTO t2_atomic
    ELSE INTO t2_atomic
SELECT * FROM src;
-- ↑ Snowsight で「成功」が表示される

-- ▶ 実行後の結果確認
-- 想定: t1_atomic=3 / t2_atomic=8（基礎編 t1 / t2 と同件数）
SELECT 't1_atomic' AS tbl, COUNT(*) AS cnt FROM t1_atomic
UNION ALL
SELECT 't2_atomic', COUNT(*) FROM t2_atomic;

-- 全件確認: t1_atomic / t2_atomic に正しいレコードが入っているか
SELECT 't1_atomic' AS tbl, pirate_name, booty_amount, rank, ship_name
FROM t1_atomic
ORDER BY booty_amount DESC;

SELECT 't2_atomic' AS tbl, pirate_name, booty_amount, rank, ship_name
FROM t2_atomic
ORDER BY booty_amount DESC;


-- ============================================================
-- ② エラーパターン: 1 件のエラーで全 INSERT がロールバック
-- ============================================================

-- エラー誘発用のソーステーブル
-- booty_amount を VARCHAR 型にして、数値変換できない値を 1 件混ぜる
CREATE OR REPLACE TABLE src_error (
    pirate_name VARCHAR,
    booty_amount VARCHAR, -- ← 数値変換エラーを起こすため文字列型
    rank VARCHAR,
    ship_name VARCHAR
);

-- src の 10 件を文字列型に変換してコピー
INSERT INTO src_error
SELECT pirate_name, booty_amount::VARCHAR, rank, ship_name FROM src;

-- エラー誘発レコードを 1 件だけ追加（booty_amount に数値以外の文字列）
INSERT INTO src_error VALUES ('Buggy Pirate', 'NOT_A_NUMBER', 'Captain', 'Crash Ship');

-- ▶ エラー原因の可視化（どのレコードがエラーを起こすかを事前に確認）
-- 想定: Buggy Pirate のみ ⚠ エラー誘発、他 10 件は ✅ OK
SELECT
    pirate_name,
    booty_amount,
    rank,
    ship_name,
    IFF(TRY_TO_NUMBER(booty_amount) IS NULL, '⚠ エラー誘発（数値変換不可）', '✅ OK') AS status
FROM src_error
ORDER BY status DESC, pirate_name;

-- エラーパターン用の宛先テーブル
CREATE OR REPLACE TABLE t1_atomic_err (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE t2_atomic_err (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);

-- ▶ 実行前確認: 両ターゲットが空であることを確認
-- 想定: t1_atomic_err=0 / t2_atomic_err=0
SELECT 't1_atomic_err' AS tbl, COUNT(*) AS cnt FROM t1_atomic_err
UNION ALL
SELECT 't2_atomic_err', COUNT(*) FROM t2_atomic_err;

-- INSERT（マルチテーブル）実行（① と同じ構造、ソーステーブルだけが src → src_error に変わる）
INSERT ALL
    WHEN TO_NUMBER(booty_amount) > 700 THEN INTO t1_atomic_err -- ← Buggy Pirate でここがエラー
    WHEN rank = 'First Mate' THEN INTO t2_atomic_err
    WHEN TO_NUMBER(booty_amount) < 100 THEN INTO t1_atomic_err -- ← 同上
    WHEN TO_NUMBER(booty_amount) < 100 THEN INTO t2_atomic_err -- ← 同上
    ELSE INTO t2_atomic_err
SELECT * FROM src_error;
-- ↑ 'NOT_A_NUMBER' の TO_NUMBER 評価で実行時エラー
-- Snowsight 上では赤いエラーメッセージが表示される（これが想定動作）
-- "Numeric value 'NOT_A_NUMBER' is not recognized"

-- ▶ 実行後の結果確認
-- 想定: t1_atomic_err=0 / t2_atomic_err=0
-- ・正常な 10 件分も含めて全 INSERT が取り消される
-- ・エラー原因は Buggy Pirate 1 件だけだが、影響は全レコードに及ぶ
-- ・これが INSERT（マルチテーブル）の「原子性」: 全部成功するか、全部取り消されるかの 2 択
SELECT 't1_atomic_err' AS tbl, COUNT(*) AS cnt FROM t1_atomic_err
UNION ALL
SELECT 't2_atomic_err', COUNT(*) FROM t2_atomic_err;

-- 全件確認: 両テーブルとも空であることを目視確認
SELECT 't1_atomic_err' AS tbl, pirate_name, booty_amount, rank, ship_name
FROM t1_atomic_err
ORDER BY booty_amount DESC;

SELECT 't2_atomic_err' AS tbl, pirate_name, booty_amount, rank, ship_name
FROM t2_atomic_err
ORDER BY booty_amount DESC;

-- ▶ こういう場面で使う:
-- 複数テーブルへの同時書き込みでデータ不整合を絶対に許容できないとき。


-- ============================================================
-- SECTION 6: 実務ユースケース: セグメント自動振り分け
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- booty_amount を基準に 3 セグメント（high_value / standard / watchlist）
-- へ自動振り分けされることを確認する。
-- ------------------------------------------------------------
-- 内容: 顧客セグメント自動振り分け（データ品質ルーティング）
-- ▶ ポイント:
-- ・売上金額・スコア・ステータスなどでセグメント分けする
-- 処理がETLツール不要でSnowflake単体で完結する
-- ・新しいセグメント条件の追加もWHEN句を1行追加するだけ
-- ============================================================

CREATE OR REPLACE TABLE pirates_high_value (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE pirates_standard (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE pirates_watchlist (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);

-- ▶ 実行前確認: 各セグメントテーブルが空であることを確認
-- 想定: 全テーブル 0 件
SELECT 'pirates_high_value' AS tbl, COUNT(*) AS cnt FROM pirates_high_value
UNION ALL SELECT 'pirates_standard', COUNT(*) FROM pirates_standard
UNION ALL SELECT 'pirates_watchlist', COUNT(*) FROM pirates_watchlist;

INSERT ALL
    WHEN booty_amount >= 500 THEN INTO pirates_high_value -- VIP（高額顧客）
    WHEN booty_amount < 100 THEN INTO pirates_watchlist -- 要監視（低額・要注意）
    ELSE INTO pirates_standard -- 一般顧客
SELECT * FROM src;

-- ▶ 実行後の結果確認
-- 想定: high_value=4（booty >= 500: Henry/Jack/William/Blackbeard）/ standard=5 / watchlist=1（Stede Bonnet）
SELECT 'high_value' AS segment, COUNT(*) AS cnt FROM pirates_high_value
UNION ALL SELECT 'standard', COUNT(*) FROM pirates_standard
UNION ALL SELECT 'watchlist', COUNT(*) FROM pirates_watchlist;

-- 全件確認: 各セグメントにどの海賊が入ったかを確認
SELECT 'high_value' AS segment, pirate_name, booty_amount, rank FROM pirates_high_value
UNION ALL SELECT 'standard', pirate_name, booty_amount, rank FROM pirates_standard
UNION ALL SELECT 'watchlist', pirate_name, booty_amount, rank FROM pirates_watchlist
ORDER BY segment, booty_amount DESC;

-- ▶ こういう場面で使う:
-- 顧客 / 商品 / イベントを属性値で 3 つ以上の集合に分類したいとき。


-- ============================================================
-- SECTION 7: STREAM との組み合わせ（変更データキャプチャ）
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- STREAM が src への新規 INSERT 2 件を差分として検知し、
-- その差分のみを INSERT（マルチテーブル）で t1 / t2 にルーティングできることを確認する。
-- ------------------------------------------------------------
-- 内容: ソーステーブルへの新規データを STREAM で検知し
-- INSERT（マルチテーブル）でリアルタイムに複数テーブルへ振り分ける
-- ▶ ポイント:
-- ・STREAM は差分（新規INSERT・DELETE）を自動で追跡する
-- ・「どのデータが新しく来たか」を毎回フルスキャンせずに
-- STREAM 経由で効率よく取得できる
-- ・INSERT（マルチテーブル）と STREAM を組み合わせると
-- 「差分検知 → 複数テーブルへのルーティング」が
-- 1クエリで完結するパイプラインになる
-- ・STREAM は一度消費するとクリアされる（べき等性への注意点）
-- ・METADATA$ACTION = 'INSERT' でUPDATE/DELETE由来の
-- 差分を除外できる（UPDATE は DELETE+INSERT で表現される）
-- ============================================================

-- src に STREAM を作成（この後の INSERT を差分として検知する）
CREATE OR REPLACE STREAM src_stream ON TABLE src;

-- ▶ 実行前確認: STREAM 作成直後は差分なし
-- 想定: src_stream=0
SELECT COUNT(*) AS stream_rows FROM src_stream;

-- 新たな海賊データを src に追加（STREAM がこの変更を差分として記録）
INSERT INTO src VALUES
    ('Long John Silver', 950, 'Captain', 'Hispaniola'),
    ('Grace O''Malley', 80, 'Admiral', 'Irish Sea');

-- ▶ INSERT 後の STREAM 差分確認
-- 想定: src_stream=2（新規 INSERT 2 件分の差分を検知）
SELECT COUNT(*) AS stream_rows FROM src_stream;

-- STREAM の差分（新規 INSERT 分のみ）を INSERT ALL でルーティング
INSERT ALL
    WHEN booty_amount > 700 THEN INTO t1
    WHEN rank = 'First Mate' THEN INTO t2
    WHEN booty_amount < 100 THEN INTO t1
    WHEN booty_amount < 100 THEN INTO t2
    ELSE INTO t2
SELECT pirate_name, booty_amount, rank, ship_name
FROM src_stream
WHERE METADATA$ACTION = 'INSERT'; -- INSERT 操作の差分のみを対象

-- 新規2件が t1/t2 に正しく振り分けられたか確認
-- Long John Silver(950) → t1 のみ
-- Grace O'Malley(80) → t1 と t2 両方
SELECT 't1' AS tbl, pirate_name, booty_amount FROM t1
WHERE pirate_name IN ('Long John Silver', 'Grace O''Malley')
UNION ALL
SELECT 't2', pirate_name, booty_amount FROM t2
WHERE pirate_name IN ('Long John Silver', 'Grace O''Malley')
ORDER BY tbl, pirate_name;

-- STREAM は消費後にクリアされる（同じ STREAM を再 SELECT しても空になる）
SELECT COUNT(*) AS stream_remaining_rows FROM src_stream;

-- ▶ クリーンアップ: 検証後に STREAM を削除（コスト対策）
-- ※ STREAM 自体はコンピュート課金なしだが、ソーステーブルの変更データを
--   保持するメタデータが残るため、検証後は削除推奨。
-- ※ 後続セクション（SECTION 8 等）で src_stream は使わないため安全に DROP できる。
DROP STREAM IF EXISTS src_stream;

-- ▶ こういう場面で使う:
-- ソーステーブルの差分だけを複数テーブルへリアルタイムにルーティングするパイプライン。


-- ============================================================
-- SECTION 8: パフォーマンス・コスト比較
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- 同じ振り分けロジックを「INSERT（マルチテーブル）（1 文）」と「個別 INSERT × 2（2 文）」で実行し、
-- QUERY_HISTORY で bytes_scanned を比較する。
-- INSERT（マルチテーブル）は src を 1 回しかスキャンしないため、bytes_scanned の合計が
-- 個別 INSERT の約半分になることを確認する。
-- ------------------------------------------------------------
-- 内容: INSERT（マルチテーブル）と個別 INSERT のスキャン回数を比較する
-- ▶ ポイント:
-- ・INSERT（マルチテーブル）は src を 1 回スキャンするだけで全テーブルへの振り分けが完結
-- → QUERY_HISTORY 上は MULTI_TABLE_INSERT として 1 行で記録される
-- ・個別 INSERT で N テーブルに振り分けると src を N 回スキャン
-- → QUERY_HISTORY 上は INSERT として N 行で記録される
-- ・100 万行 × 5 テーブルなら I/O コストを約 1/5 に削減できる
-- ・トライアル環境の小データ（10 件）では差が出にくいため、Query Profile の
-- スクリーンショットで補完しつつ理論値として説明することを推奨
-- ============================================================

-- INSERT（マルチテーブル）用のテーブル（SECTION 8 専用の名前で履歴を絞りやすくする）
CREATE OR REPLACE TABLE t1_mi_cost (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE t2_mi_cost (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);

-- 個別 INSERT 用のテーブル
CREATE OR REPLACE TABLE t1_separate (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
CREATE OR REPLACE TABLE t2_separate (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);

-- ▶ 実行前確認: 全 4 テーブルが空
-- 想定: 全テーブル 0 件
SELECT 't1_mi_cost' AS tbl, COUNT(*) AS cnt FROM t1_mi_cost
UNION ALL SELECT 't2_mi_cost', COUNT(*) FROM t2_mi_cost
UNION ALL SELECT 't1_separate', COUNT(*) FROM t1_separate
UNION ALL SELECT 't2_separate', COUNT(*) FROM t2_separate;

-- ───── INSERT（マルチテーブル）: 1 文で完結 → src を 1 回スキャン ─────
INSERT ALL
    WHEN booty_amount > 700 THEN INTO t1_mi_cost
    WHEN rank = 'First Mate' THEN INTO t2_mi_cost
    WHEN booty_amount < 100 THEN INTO t1_mi_cost
    WHEN booty_amount < 100 THEN INTO t2_mi_cost
    ELSE INTO t2_mi_cost
SELECT * FROM src;

-- ───── 個別 INSERT × 2: 2 文 → src を 2 回スキャン ─────
INSERT INTO t1_separate
    SELECT * FROM src WHERE booty_amount > 700 OR booty_amount < 100;

INSERT INTO t2_separate
    SELECT * FROM src
    WHERE rank = 'First Mate'
       OR booty_amount < 100
       OR (booty_amount BETWEEN 100 AND 700 AND rank != 'First Mate');

-- ▶ 件数確認: 全方法で同じ件数になる（コストだけが違うことを示す前準備）
-- 想定:
-- ・src=10 件のとき: t1_mi_cost=3 / t2_mi_cost=8 / t1_separate=3 / t2_separate=8
-- ・src=12 件のとき（SECTION 7 後）: t1 系=5 / t2 系=9 で全方法一致
SELECT 't1_mi_cost' AS tbl, COUNT(*) AS cnt FROM t1_mi_cost
UNION ALL SELECT 't2_mi_cost', COUNT(*) FROM t2_mi_cost
UNION ALL SELECT 't1_separate', COUNT(*) FROM t1_separate
UNION ALL SELECT 't2_separate', COUNT(*) FROM t2_separate;

-- ▶ コスト比較①: 直近の INSERT 3 件をメソッドラベル付きで詳細表示
-- 見方:
-- ・method 列で ①INSERT（マルチテーブル）/ ②個別 INSERT(t1) / ③個別 INSERT(t2) を識別
-- ・bytes_scanned が src のスキャン量
-- ・LIMIT 3 で最新実行のみに絞り、過去履歴を除外
SELECT
    CASE
        WHEN query_text ILIKE 'INSERT ALL%' THEN '① INSERT（マルチテーブル）（1 文で完結）'
        WHEN query_text ILIKE 'INSERT INTO t1_separate%' THEN '② 個別 INSERT → t1_separate'
        WHEN query_text ILIKE 'INSERT INTO t2_separate%' THEN '③ 個別 INSERT → t2_separate'
    END AS method,
    bytes_scanned,
    rows_produced AS inserted_rows,
    execution_time / 1000.0 AS execution_sec
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE (query_text ILIKE 'INSERT ALL%t1_mi_cost%'
    OR query_text ILIKE 'INSERT INTO t1_separate%'
    OR query_text ILIKE 'INSERT INTO t2_separate%')
ORDER BY start_time DESC
LIMIT 3;

-- ▶ コスト比較②: 方式ごとに合計（INSERT（マルチテーブル）1 文 vs 個別 INSERT 2 文合計）
-- 見方:
-- ・method = INSERT（マルチテーブル）→ 1 文・1 スキャン
-- ・method = 個別 INSERT → 2 文の bytes_scanned 合計
-- ・total_bytes_scanned で「個別 INSERT が INSERT（マルチテーブル）の約 2 倍」になっていれば理論通り
-- ・statement_count = SQL 文数（1 vs 2）
WITH recent_inserts AS (
    SELECT
        CASE WHEN query_text ILIKE 'INSERT ALL%' THEN 'INSERT（マルチテーブル）' ELSE '個別 INSERT' END AS method,
        bytes_scanned,
        rows_produced,
        execution_time,
        start_time
    FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
    WHERE (query_text ILIKE 'INSERT ALL%t1_mi_cost%'
        OR query_text ILIKE 'INSERT INTO t1_separate%'
        OR query_text ILIKE 'INSERT INTO t2_separate%')
    ORDER BY start_time DESC
    LIMIT 3
)
SELECT
    method,
    COUNT(*) AS statement_count,
    SUM(bytes_scanned) AS total_bytes_scanned,
    SUM(rows_produced) AS total_inserted_rows,
    SUM(execution_time) / 1000.0 AS total_execution_sec
FROM recent_inserts
GROUP BY method
ORDER BY method;

-- ▶ こういう場面で使う:
-- 大量データを複数テーブルへ振り分けるとき、スキャン回数を抑えてコスト削減したい場合。


-- ============================================================
-- SECTION 9: MERGE との使い分け
-- ------------------------------------------------------------
-- ▶ ここで確認すること:
-- INSERT（マルチテーブル）では重複行（William Kidd が 2 行）が生じるのに対し、
-- MERGE では既存を UPDATE / 新規を INSERT して
-- 重複なく upsert できることを確認する。
-- ------------------------------------------------------------
-- 内容: INSERT（マルチテーブル）では実現できない「既存データの更新」が
-- 必要な場合に MERGE を使うべきことを示す
-- ▶ ポイント:
-- ・INSERT（マルチテーブル）は「新規データの振り分け専用」であり
-- 既存レコードの更新機能を持たない
-- ・同じキーのデータを再挿入すると重複行が生まれる
-- → 「upsert（更新 or 挿入）」が必要な場面では MERGE を使う
-- ・INSERT（マルチテーブル）と MERGE の使い分け基準:
-- 新規データを複数テーブルに振り分けたい → INSERT（マルチテーブル）
-- 既存データを更新しつつ新規も受け入れたい → MERGE
-- ・「どちらが優れているか」ではなく「目的に応じた選択」が重要
-- ============================================================

-- ──────────────────────────────────────────────────────────────
-- このセクション用に、マスタ + 履歴の 2 テーブルを 1 から作成
-- （マルチテーブル構成で INSERT（マルチテーブル）と MERGE の特性差を見せるため）
-- ──────────────────────────────────────────────────────────────

-- マスタテーブル: 海賊の最新情報
CREATE OR REPLACE TABLE pirates_master (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);

-- 変更履歴テーブル: 操作リクエストの記録（INSERT（マルチテーブル）の書き込み先）
CREATE OR REPLACE TABLE pirates_history (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR,
    operation VARCHAR,
    operated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- SECTION 9 専用の初期データを 4 件ハードコードで投入
-- （前セクション SECTION 7 で src に行が追加されていても影響を受けないように
--   src を SELECT せず、このセクションだけで完結する固定データを使う）
-- 主役は William Kidd（booty=600 → ③ の MERGE で 900 に更新する対象）
INSERT INTO pirates_master (pirate_name, booty_amount, rank, ship_name) VALUES
    ('Blackbeard', 500, 'Captain', 'Queen Anne''s Revenge'),
    ('Anne Bonny', 300, 'First Mate', 'Revenge'),
    ('Jack Sparrow', 800, 'Captain', 'Black Pearl'),
    ('William Kidd', 600, 'Captain', 'Adventure Galley');

-- ▶ 実行前確認①: pirates_master の初期状態（全 4 件）
-- 想定: 4 件
SELECT pirate_name, booty_amount, rank, ship_name
FROM pirates_master
ORDER BY booty_amount DESC;

-- ▶ 実行前確認②: 以降の比較で使うフォーカスクエリ（対象: William Kidd / Ned Low）
-- 想定: William Kidd / booty=600 の 1 行のみ（Ned Low は未登録）
-- ★この SELECT を ①③ の結果確認でも同じ文面で再実行し、状態変化を一貫して観察する
SELECT pirate_name, booty_amount
FROM pirates_master
WHERE pirate_name IN ('William Kidd', 'Ned Low')
ORDER BY pirate_name, booty_amount;

-- ▶ 実行前確認③: pirates_history が空であることを確認
-- 想定: 0 件
SELECT COUNT(*) AS history_count FROM pirates_history;

-- シナリオ: William Kidd の戦利品が更新 + 新海賊が追加された
CREATE OR REPLACE TABLE src_updates (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
INSERT INTO src_updates VALUES
    ('William Kidd', 900, 'Captain', 'Adventure Galley'), -- 既存レコード（600→900 に更新したい）
    ('Ned Low', 450, 'Captain', 'Fancy'); -- 新規レコード

-- ▶ 実行前確認④: src_updates の中身
-- 想定: 2 件（William Kidd 900 と Ned Low 450）
SELECT * FROM src_updates;

-- ══════════════════════════════════════════════════════════════
-- ① INSERT（マルチテーブル）でやってみる → 重複データが入る（限界の実演）
-- ══════════════════════════════════════════════════════════════
-- マスタと履歴の 2 テーブルに同時書き込み（INSERT（マルチテーブル）の本来の使い方）
-- ★ただし INSERT（マルチテーブル）は「新規挿入」専用なので、既存 William Kidd は
--   上書きされず、マスタに重複行ができてしまう ← ここを見せたい
INSERT ALL
    INTO pirates_master (pirate_name, booty_amount, rank, ship_name)
    INTO pirates_history (pirate_name, booty_amount, rank, ship_name, operation)
        VALUES (pirate_name, booty_amount, rank, ship_name, 'UPSERT_REQUESTED')
SELECT * FROM src_updates;

-- ▶ ①の結果A: 実行前確認②と同じ SELECT を再実行（state 比較）
-- ★想定: 3 行
--   - William Kidd / booty=600（元のレコード、消えていない）
--   - William Kidd / booty=900（新規追加された行）← ★ ここが重複！
--   - Ned Low      / booty=450（新規追加）
-- → INSERT（マルチテーブル）は「既存を更新する」機能を持たないため William Kidd が 2 行に増えてしまう
SELECT pirate_name, booty_amount
FROM pirates_master
WHERE pirate_name IN ('William Kidd', 'Ned Low')
ORDER BY pirate_name, booty_amount;

-- ▶ ①の結果B: 履歴には 2 件の操作リクエストが正しく記録される（INSERT（マルチテーブル）の利点）
-- 想定: pirates_history=2 件（William Kidd と Ned Low、operation='UPSERT_REQUESTED'）
SELECT * FROM pirates_history;


-- ══════════════════════════════════════════════════════════════
-- ② マスタを初期状態に戻す（INSERT（マルチテーブル）の影響をクリア）
-- ══════════════════════════════════════════════════════════════
-- 目的: MERGE が「既存レコードを正しく UPDATE する」ことを次の ③ で実演するため、
-- ① で書き込まれたデータを丸ごとリセットして、テーブルを最初の状態に戻す。
-- 個別 DELETE ではなく CREATE OR REPLACE + INSERT で作り直すことで、
-- 「確実に初期状態へ戻った」ことを担保する。
CREATE OR REPLACE TABLE pirates_master (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR
);
-- SECTION 9 専用の初期データ 4 件を再投入（冒頭と同じ内容）
INSERT INTO pirates_master (pirate_name, booty_amount, rank, ship_name) VALUES
    ('Blackbeard', 500, 'Captain', 'Queen Anne''s Revenge'),
    ('Anne Bonny', 300, 'First Mate', 'Revenge'),
    ('Jack Sparrow', 800, 'Captain', 'Black Pearl'),
    ('William Kidd', 600, 'Captain', 'Adventure Galley');

CREATE OR REPLACE TABLE pirates_history (
    pirate_name VARCHAR,
    booty_amount NUMBER,
    rank VARCHAR,
    ship_name VARCHAR,
    operation VARCHAR,
    operated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- ▶ ②の結果A: 実行前確認②と同じ SELECT を再実行（state 比較）
-- 想定: 実行前確認②と完全に同じ結果に戻る
--   - William Kidd / booty=600 の 1 行のみ
--   - Ned Low は再び存在しない
SELECT pirate_name, booty_amount
FROM pirates_master
WHERE pirate_name IN ('William Kidd', 'Ned Low')
ORDER BY pirate_name, booty_amount;

-- ▶ ②の結果B: pirates_history が空に戻る
-- 想定: 0 件
SELECT COUNT(*) AS history_count FROM pirates_history;


-- ══════════════════════════════════════════════════════════════
-- ③ MERGE でやってみる → 既存は UPDATE / 新規は INSERT で正しく upsert
-- ══════════════════════════════════════════════════════════════
-- ★ INSERT（マルチテーブル）とは違い、MERGE なら既存 William Kidd が 1 行のまま booty=900 に更新される
-- ※ MERGE は単一テーブル対象。マルチテーブル upsert は MERGE × N 文か、
--   STREAM / TASK / プロシージャを組み合わせる必要がある。
MERGE INTO pirates_master AS target
USING src_updates AS source
    ON target.pirate_name = source.pirate_name
WHEN MATCHED THEN
    UPDATE SET booty_amount = source.booty_amount -- 既存レコードを更新
WHEN NOT MATCHED THEN
    INSERT (pirate_name, booty_amount, rank, ship_name)
    VALUES (source.pirate_name, source.booty_amount, source.rank, source.ship_name);

-- ▶ ③の結果: 実行前確認②と同じ SELECT を再実行（state 比較）
-- ★想定: 2 行（① のときと比べて William Kidd が 1 行になっている）
--   - William Kidd / booty=900 ← booty_amount が 600 → 900 に【更新】された（重複なし）
--   - Ned Low      / booty=450 ← 新規 INSERT された
-- → MERGE は既存キーを UPDATE するため、INSERT（マルチテーブル）のような重複行が発生しない
SELECT pirate_name, booty_amount
FROM pirates_master
WHERE pirate_name IN ('William Kidd', 'Ned Low')
ORDER BY pirate_name, booty_amount;


-- ══════════════════════════════════════════════════════════════
-- ④ ① と ③ の対比サマリ（結論）
-- ══════════════════════════════════════════════════════════════
-- ★ 同じ SELECT を 3 回実行した結果の差分（William Kidd / Ned Low フォーカス）
--
--   状態                              William Kidd          Ned Low
--   実行前（=②の結果）               1 行 (booty=600)      存在しない
--   ① INSERT（マルチテーブル）後      2 行 (600 と 900)★    1 行 (450)
--   ③ MERGE 後                        1 行 (booty=900)★     1 行 (450)
--
-- INSERT（マルチテーブル）:
--   ・新規挿入専用
--   ・既存キーがあると重複行発生
--   ・マルチテーブル可（1 文で複数 INTO）
--
-- MERGE:
--   ・既存は UPDATE、新規は INSERT
--   ・重複行は発生しない
--   ・単一テーブル対象
--
--   → 「既存データの更新が必要」なら MERGE 一択
--   → 「複数テーブルへの同時書き込み」なら INSERT（マルチテーブル）
--   → 両方必要なら組み合わせる（マスタ=MERGE、履歴=INSERT（マルチテーブル）など）

-- ▶ こういう場面で使う:
-- 既存データを更新しつつ新規も同時に受け入れたいとき（upsert）。
-- INSERT（マルチテーブル）ではなく MERGE を選ぶ判断基準。


-- ============================================================
-- 全体まとめ: 今回作成した全テーブルの一覧と件数
-- ============================================================
SELECT table_name, row_count
FROM information_schema.tables
WHERE table_schema = 'WEEK101'
ORDER BY table_name;
