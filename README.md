# RDS Reserved Instance 一括購入スクリプト

AWS CloudShell で RDS/Aurora の Reserved Instance を確認、一括購入するスクリプトです。

## 前提条件

- AWS CloudShell 環境（AWS CLI v2）
- RDS Reserved Instance 購入権限を持つ IAM ロール
- `jq` コマンド（CloudShell にプリインストール済み）

## 使用方法

### 1. 入力ファイルの準備

CSV形式で購入情報を記載します。

csv
region,db_type,instance_class,engine,multi_az,quantity,duration,payment_option
ap-northeast-1,RDS,db.t3.medium,mysql,yes,2,1,No Upfront
ap-northeast-1,Aurora,db.r5.large,aurora-mysql,no,3,3,No Upfront

**フィールド説明:**
- `region`: ap-northeast-1 または ap-northeast-3 のみ
- `db_type`: RDS または Aurora
- `instance_class`: db.xxx.xxx 形式
- `engine`: 以下のいずれか
  - OSS系: aurora-mysql, aurora-postgresql, mysql, postgresql, mariadb
  - Oracle: oracle-se2, oracle-ee, oracle-se2-byol, oracle-ee-byol
  - RDS Custom (Oracle): custom-oracle-ee-byol, custom-oracle-se2-byol
  - SQL Server: sqlserver-ex, sqlserver-ee, sqlserver-se, sqlserver-web, sqlserver-ee-byol, sqlserver-se-byol
  - RDS Custom (SQL Server): custom-sqlserver-ee, custom-sqlserver-se, custom-sqlserver-web, custom-sqlserver-ee-byol, custom-sqlserver-se-byol
  - Db2: db2-ae, db2-ae-byol, db2-se, db2-se-byol
- `multi_az`: yes または no（Aurora の場合は無視）
- `quantity`: 購入数量（上限: 50）
- `duration`: 1 または 3（年）
- `payment_option`: No Upfront のみ

### 2. 検証実行（デフォルト）

bash
./rds-ri-launchpad.sh input.csv

購入は実行されず、検証のみ行われます。

### 3. 実際の購入

bash
./rds-ri-launchpad.sh --purchase input.csv

**推奨実行時刻:** 4月1日 09:00-09:59（JST）

### 4. 結果確認

実行後、`ri_purchase_result_YYYYMMDD_HHMMSS.txt` が生成されます。

bash
cat ri_purchase_result_*.txt

## 制限事項

- **リージョン:** 東京（ap-northeast-1）、大阪（ap-northeast-3）のみ
- **支払いオプション:** No Upfront のみ
- **並行実行:** 同じ入力ファイルでの並行実行は不可（ロックファイル機構）
- **データ行数:** 1回の実行あたり最大100行

## セキュリティ機能

- パストラバーサル対策
- インスタンスクラス形式検証
- エンジン名ホワイトリスト検証
- 結果ファイルのパーミッション制限（600）
- 購入エラー出力からのアカウント固有情報の除去

## エラーハンドリング

スクリプトは以下のエラーを自動的に処理します:

### 入力検証エラー
- **親ディレクトリ参照(..)検出** → 即座に終了
- **ファイル不存在** → エラーメッセージ表示後終了
- **データ行数上限超過** → エラーメッセージ表示後終了
- **不正なインスタンスクラス形式** → 該当行をスキップ
- **無効なエンジン名** → 該当行をスキップ
- **リージョン制限違反** → 該当行をスキップ
- **支払いオプション制限違反** → 該当行をスキップ
- **無効な数量/期間** → 該当行をスキップ

### API エラー
- **Offering 取得失敗** → 該当行をスキップ、次の行を処理継続
- **購入API失敗** → エラー詳細を表示、次の行を処理継続
- **AWS認証エラー** → スクリプト終了（初回の `sts get-caller-identity` および Offering 取得時の認証エラーの両方で検知）

### 実行制御
- **並行実行検出** → ロックファイルでブロック、エラーメッセージ表示
- **購入可能項目なし** → 検証結果表示後終了
- **確認プロンプトでno** → 安全に終了

### 終了コード
- `0`: 正常終了（検証のみ、または購入成功）
- `1`: エラー終了（入力エラー、全購入失敗、購入可能項目なし、認証エラー）

## トラブルシューティング

### Offering が見つからない
- インスタンスクラス、エンジン、MultiAZ の組み合わせを確認
- リージョンで提供されているか AWS コンソールで確認

### 購入失敗
- IAM 権限を確認（`rds:PurchaseReservedDBInstancesOffering`）
- アカウントの購入制限を確認
- エラーメッセージの詳細を確認

### 一部の購入が失敗した場合
- 結果ファイル（`ri_purchase_result_*.txt`）で失敗した行を確認してください
- 失敗した行のみを記載した新しいCSVファイルを作成し、再実行することで手動リトライが可能です

### スロットリング・APIエラーが多発する場合
- 本スクリプトは1回の実行あたり10〜100行程度の入力を想定しています
- 大量の入力（100行超）を処理する場合、AWS APIのスロットリングが発生する可能性があります
- その場合はCSVファイルを分割し、複数回に分けて実行してください

### ロックファイルエラー
bash
rm -rf /tmp/rds_ri_purchase_lock

### AWS CLI エラー
bash
# 認証情報確認
aws sts get-caller-identity

# RDS API 疎通確認
aws rds describe-reserved-db-instances-offerings --region ap-northeast-1 --max-records 1

## 稼働インスタンス数の確認について

稼働中インスタンス数の取得は AWS CLI v2 のクライアントサイド自動ページネーションに依存しています。100台を超えるインスタンスがある環境でも全件が取得されますが、AWS CLI v1 環境では正しく動作しない可能性があります。

## サンプル

bash
# 検証のみ
./rds-ri-launchpad.sh sample.csv

# 購入実行
./rds-ri-launchpad.sh --purchase sample.csv

## 注意事項

このスクリプトはサンプルとして提供されています。使用は自己責任でお願いします。本番環境での使用前に必ずテスト環境で動作確認してください。
