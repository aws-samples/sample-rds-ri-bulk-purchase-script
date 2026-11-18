#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# RDS/Aurora Reserved Instance 一括購入スクリプト v3.8 (Security Reviewed)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

MAX_DATA_LINES=100

# フィールド前後の空白を除去
trim() { echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

show_usage() {
  echo "使用方法: $0 [--purchase] <input_file>"
  echo "オプション: --purchase  実際に購入を実行（デフォルトは検証のみ）"
  echo "入力形式: region,db_type,instance_class,engine,multi_az,quantity,duration,payment_option"
  exit 1
}

# CSVのengine値から、API検索用のフィルタ値と、期待する ProductDescription（完全一致）を求める
# --product-description フィルタは部分一致のため、例えば "oracle-se2" で検索すると
# "oracle-se2(li)" と "oracle-se2 (byol)" の両方が返る。先頭1件を使うと意図しない
# ライセンスモデルを購入しうるため、レスポンスの ProductDescription を完全一致で絞り込む。
# リージョンにより表記の空白が異なる（東京 "oracle-se2 (byol)" / 大阪 "oracle-se2 (li)" など）ため、
# 空白を除去した値で比較する。値は ap-northeast-1 / ap-northeast-3 の実レスポンスで確認済み。
api_filter_engine() {
  echo "${1%-byol}"
}

expected_product_description() {
  case "$1" in
    aurora-mysql|aurora-postgresql|mysql|postgresql|mariadb) echo "$1" ;;
    oracle-se2) echo "oracle-se2(li)" ;;
    oracle-se2-byol) echo "oracle-se2(byol)" ;;
    oracle-ee-byol) echo "oracle-ee(byol)" ;;
    sqlserver-ee|sqlserver-se|sqlserver-web) echo "$1(li)" ;;
    db2-ae|db2-se) echo "$1(mpl)" ;;
    db2-ae-byol|db2-se-byol) echo "${1%-byol}(byol)" ;;
    *) echo "" ;;  # RIが存在しない組み合わせ（oracle-ee LI、RDS for SQL Server BYOL など）
  esac
}

validate_line() {
  local region=$1 db_type=$2 instance_class=$3 engine=$4 payment=$5 quantity=$6 duration_years=$7 multi_az=$8

  [[ ! "$instance_class" =~ ^db\.[a-z0-9]+\.[a-z0-9]+$ ]] && echo "インスタンスクラス形式が無効: $instance_class" && return 1

  # RI購入対応エンジンのみ許可
  # - sqlserver-ex (Express) と custom-* (RDS Custom) は本スクリプトの対象外として除外
  #   （RI 非対応ではない。東京リージョンなどでは RI が提供されているが、本スクリプトでは扱わない）
  case "$engine" in
    aurora-mysql|aurora-postgresql|mysql|postgresql|mariadb) ;;
    oracle-se2|oracle-se2-byol|oracle-ee-byol) ;;
    oracle-ee) echo "RI非対応: Oracle EE はライセンス込み(LI)のRIがありません。BYOLの場合は oracle-ee-byol を指定してください" && return 1 ;;
    sqlserver-ee|sqlserver-se|sqlserver-web) ;;
    sqlserver-ee-byol|sqlserver-se-byol) echo "RI非対応: RDS for SQL Server にBYOLのRIはありません: $engine" && return 1 ;;
    db2-ae|db2-ae-byol|db2-se|db2-se-byol) ;;
    sqlserver-ex) echo "対象外: SQL Server Express は本スクリプトの対象外です" && return 1 ;;
    custom-*) echo "対象外: RDS Custom ($engine) は本スクリプトの対象外です" && return 1 ;;
    *) echo "エンジン名が無効: $engine" && return 1 ;;
  esac

  [ "$region" != "ap-northeast-1" ] && [ "$region" != "ap-northeast-3" ] && echo "リージョン制限: $region" && return 1
  [ "$payment" != "No Upfront" ] && echo "支払いオプション制限: $payment" && return 1
  # 数量バリデーション — 1以上の整数のみ許可
  if [[ ! "$quantity" =~ ^[1-9][0-9]*$ ]]; then
    echo "数量が無効: $quantity" && return 1
  fi
  # 大量購入防止のため上限チェック
  if [ "$quantity" -gt 50 ]; then
    echo "数量が上限超過: $quantity (上限: 50)" && return 1
  fi
  [ "$duration_years" != "1" ] && [ "$duration_years" != "3" ] && echo "期間が無効: $duration_years" && return 1
  [ "$db_type" != "RDS" ] && [ "$db_type" != "Aurora" ] && echo "DB種別が無効: $db_type" && return 1
  # multi_az は RDS では yes/no 必須（タイプミスを Single-AZ として購入しないため）。Aurora では無視するが値は yes/no/空 のみ許可
  if [ "$db_type" = "RDS" ]; then
    [ "$multi_az" != "yes" ] && [ "$multi_az" != "no" ] && echo "multi_azが無効: '$multi_az' (yes または no)" && return 1
  else
    [ -n "$multi_az" ] && [ "$multi_az" != "yes" ] && [ "$multi_az" != "no" ] && echo "multi_azが無効: '$multi_az' (yes / no / 空)" && return 1
  fi

  return 0
}

DRY_RUN=true
INPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --purchase) DRY_RUN=false; shift ;;
    -h|--help) show_usage ;;
    *) INPUT_FILE="$1"; shift ;;
  esac
done

[ -z "${INPUT_FILE:-}" ] && show_usage
# パストラバーサル対策: 親ディレクトリ参照(..)を含むパスを禁止
[[ "$INPUT_FILE" =~ \.\. ]] && echo -e "${RED}エラー: 親ディレクトリ参照(..)を含むパスは許可されていません${NC}" && exit 1
[ ! -f "$INPUT_FILE" ] && echo -e "${RED}エラー: ファイルが見つかりません: $INPUT_FILE${NC}" && exit 1

# 入力ファイルのデータ行数チェック（空行・コメント・ヘッダーを除外）
DATA_LINE_COUNT=$(grep -cvE '^\s*$|^\s*#|^region,' "$INPUT_FILE" || true)
if [ "$DATA_LINE_COUNT" -gt "$MAX_DATA_LINES" ]; then
  echo -e "${RED}エラー: データ行数が上限(${MAX_DATA_LINES}行)を超えています: ${DATA_LINE_COUNT}行${NC}"
  echo -e "${YELLOW}CSVファイルを分割して複数回に分けて実行してください${NC}"
  exit 1
fi

# 並行実行防止（実行ユーザーのホーム配下に置き、他ユーザーによる先取りを防ぐ）
if command -v flock >/dev/null 2>&1; then
  # flock はプロセス終了時（異常終了・SIGKILL を含む）にカーネルが自動で解除するため、
  # 古いロックが残らず、自動解除処理による競合も発生しない（CloudShell / Amazon Linux など）
  LOCK_FILE="${HOME}/.rds_ri_purchase.lock"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo -e "${RED}エラー: 既に実行中です（ロック: ${LOCK_FILE}）${NC}" && exit 1
  fi
else
  # flock がない環境（macOS など）は mkdir で排他する。
  # 他プロセスのロックを誤って削除しないよう、古いロックの自動解除は行わない
  LOCK_DIR="${HOME}/.rds_ri_purchase_lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo -e "${RED}エラー: 既に実行中か、前回の異常終了でロックが残っています（ロック: ${LOCK_DIR}）${NC}"
    echo -e "${YELLOW}他に実行中のプロセスがないことを確認のうえ、rm -rf \"${LOCK_DIR}\" で削除してから再実行してください${NC}"
    exit 1
  fi
  trap 'rm -rf "$LOCK_DIR"' EXIT
fi
# Ctrl+C / TERM では処理を継続せず終了する（EXIT トラップでロックを解除）
trap 'exit 130' INT
trap 'exit 143' TERM

echo -e "${YELLOW}サンプルスクリプト - 使用は自己責任でお願いします${NC}\n"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EXECUTION_TIME=$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')

echo -e "${CYAN}RDS/Aurora RI 購入スクリプト v3.8${NC}"
echo -e "アカウント: ${GREEN}${ACCOUNT_ID}${NC}"
echo -e "入力: ${GREEN}${INPUT_FILE}${NC}"
if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}モード: 検証のみ（購入するには --purchase オプションを指定）${NC}"
else
  echo -e "${YELLOW}モード: 購入実行${NC}"
fi
echo ""

LINE_NUM=0
SKIP_COUNT=0
BLANK_COUNT=0
COMMENT_COUNT=0
HEADER_SKIPPED=false
declare -a PURCHASE_QUEUE=()
declare -a RESULTS=()

echo -e "${CYAN}検証中...${NC}"

# Windows改行(CR)を除去し、各フィールドはtrim関数で前後の空白も除去
while IFS=',' read -r REGION DB_TYPE DB_INSTANCE_CLASS ENGINE MULTI_AZ_INPUT QUANTITY DURATION_YEARS PAYMENT_OPTION || [ -n "${REGION:-}" ]; do
  LINE_NUM=$((LINE_NUM + 1))

  REGION=$(trim "${REGION:-}")
  DB_TYPE=$(trim "${DB_TYPE:-}")
  DB_INSTANCE_CLASS=$(trim "${DB_INSTANCE_CLASS:-}")
  ENGINE=$(trim "${ENGINE:-}")
  MULTI_AZ_INPUT=$(trim "${MULTI_AZ_INPUT:-}")
  QUANTITY=$(trim "${QUANTITY:-}")
  DURATION_YEARS=$(trim "${DURATION_YEARS:-}")
  PAYMENT_OPTION=$(trim "${PAYMENT_OPTION:-}")

  [ -z "$REGION" ] && BLANK_COUNT=$((BLANK_COUNT + 1)) && continue
  [[ "$REGION" =~ ^# ]] && COMMENT_COUNT=$((COMMENT_COUNT + 1)) && continue

  # ヘッダー行スキップ
  if [ "$HEADER_SKIPPED" = false ] && [ "$REGION" = "region" ]; then
    HEADER_SKIPPED=true
    COMMENT_COUNT=$((COMMENT_COUNT + 1))
    continue
  fi

  echo -e "${CYAN}[行 $LINE_NUM]${NC} $REGION, $DB_TYPE, $DB_INSTANCE_CLASS, $ENGINE, x$QUANTITY, ${DURATION_YEARS}年"

  if ! VALIDATION_ERROR=$(validate_line "$REGION" "$DB_TYPE" "$DB_INSTANCE_CLASS" "$ENGINE" "$PAYMENT_OPTION" "$QUANTITY" "$DURATION_YEARS" "$MULTI_AZ_INPUT" 2>&1); then
    echo -e "  ${RED}✗ $VALIDATION_ERROR${NC}"
    RESULTS+=("行 $LINE_NUM: SKIP - $VALIDATION_ERROR")
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  [ "$DURATION_YEARS" = "1" ] && DURATION="31536000" || DURATION="94608000"

  if [ "$DB_TYPE" = "Aurora" ]; then
    MULTI_AZ_FLAG="--no-multi-az"
    MULTI_AZ_BOOL="false"
  else
    if [ "$MULTI_AZ_INPUT" = "yes" ]; then
      MULTI_AZ_FLAG="--multi-az"
      MULTI_AZ_BOOL="true"
    else
      MULTI_AZ_FLAG="--no-multi-az"
      MULTI_AZ_BOOL="false"
    fi
  fi

  # CSVのengine値からAPI用のproduct-description値へ変換
  API_ENGINE=$(api_filter_engine "$ENGINE")
  PRODUCT_DESC=$(expected_product_description "$ENGINE")

  # 期待する ProductDescription が求まらない場合はスキップ（validate_lineで排除済みだが防御的に）
  if [ -z "$PRODUCT_DESC" ]; then
    echo -e "  ${RED}✗ エンジン名のマッピングに失敗: $ENGINE${NC}"
    RESULTS+=("行 $LINE_NUM: SKIP - エンジン名マッピング失敗: $ENGINE")
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # MULTI_AZ_FLAG は意図的にクォートなし（--multi-az / --no-multi-az をフラグとして展開するため）
  # shellcheck disable=SC2086
  # offering-type は防御的にハードコード（validate_lineで No Upfront 以外は既に排除済みだが、
  # 万が一バリデーションにバグがあっても意図しない前払い購入を防止するため）
  # フィルタは部分一致のため、ProductDescription を完全一致で絞り込み、ちょうど1件の場合のみ採用する
  OFFERINGS=$(aws rds describe-reserved-db-instances-offerings \
    --region "${REGION}" \
    --db-instance-class "${DB_INSTANCE_CLASS}" \
    --product-description "${API_ENGINE}" \
    ${MULTI_AZ_FLAG} \
    --duration "${DURATION}" \
    --offering-type "No Upfront" \
    --query 'ReservedDBInstancesOfferings[].[ReservedDBInstancesOfferingId,FixedPrice,RecurringCharges[0].RecurringChargeAmount,CurrencyCode,ProductDescription]' \
    --output json 2>&1) || {
    if echo "$OFFERINGS" | grep -qE 'ExpiredToken|AccessDenied|AuthFailure|InvalidClientTokenId|UnrecognizedClientException|SignatureDoesNotMatch|UnauthorizedOperation'; then
      echo -e "  ${RED}✗ 認証エラーが発生しました。スクリプトを終了します${NC}"
      exit 1
    fi
    OFFERINGS=""
  }

  if [ -z "${OFFERINGS:-}" ] || [ "$OFFERINGS" = "null" ] || [ "$OFFERINGS" = "[]" ]; then
    echo -e "  ${RED}✗ Offering not found${NC}"
    RESULTS+=("行 $LINE_NUM: FAIL - Offering not found")
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # ProductDescription を空白除去して完全一致する候補だけを残す
  OFFERINGS=$(echo "$OFFERINGS" | jq -c --arg pd "$PRODUCT_DESC" '[.[] | select((.[4] | gsub(" "; "")) == $pd)]')
  OFFERING_COUNT=$(echo "$OFFERINGS" | jq 'length')
  if [ "$OFFERING_COUNT" != "1" ]; then
    echo -e "  ${RED}✗ Offering が一意に決まりません（${OFFERING_COUNT}件, ${PRODUCT_DESC}）${NC}"
    RESULTS+=("行 $LINE_NUM: FAIL - Offering not unique (${OFFERING_COUNT}件, ${PRODUCT_DESC})")
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  OFFERING_ID=$(echo "$OFFERINGS" | jq -r '.[0][0]')
  FIXED_PRICE=$(echo "$OFFERINGS" | jq -r '.[0][1]')
  RECURRING_PRICE=$(echo "$OFFERINGS" | jq -r '.[0][2]')
  CURRENCY=$(echo "$OFFERINGS" | jq -r '.[0][3]')

  echo -e "  ${GREEN}✓ Offering: $OFFERING_ID [$PRODUCT_DESC] (前払: $FIXED_PRICE $CURRENCY, 時間単価: $RECURRING_PRICE $CURRENCY)${NC}"

  # describe-db-instancesのEngine値はライセンスモデルに依存しない（例: oracle-se2はLI/BYOL共通）
  # RI OfferingのCSV engine値（oracle-se2-byol等）からベースエンジン名を抽出して検索する
  SEARCH_ENGINE=$(echo "$ENGINE" | sed 's/-byol$//')

  if [ "$DB_TYPE" = "Aurora" ]; then
    # AWS CLI v2のクライアントサイド自動ページネーションにより全件取得される
    RUNNING_COUNT=$(aws rds describe-db-instances --region "${REGION}" \
      --query "DBInstances[?DBInstanceClass==\`${DB_INSTANCE_CLASS}\` && starts_with(Engine, \`${SEARCH_ENGINE}\`) && DBInstanceStatus==\`available\`] | length(@)" \
      --output text 2>&1) || {
      echo -e "  ${YELLOW}⚠ 稼働インスタンス数の取得に失敗しました${NC}"
      RUNNING_COUNT="-"
    }
  else
    # MultiAZ は bool 型。JMESPath のバッククォートは JSON リテラルなので `true`/`false` は bool として比較される
    # AWS CLI v2のクライアントサイド自動ページネーションにより全件取得される
    RUNNING_COUNT=$(aws rds describe-db-instances --region "${REGION}" \
      --query "DBInstances[?DBInstanceClass==\`${DB_INSTANCE_CLASS}\` && Engine==\`${SEARCH_ENGINE}\` && MultiAZ==\`${MULTI_AZ_BOOL}\` && DBInstanceStatus==\`available\`] | length(@)" \
      --output text 2>&1) || {
      echo -e "  ${YELLOW}⚠ 稼働インスタンス数の取得に失敗しました${NC}"
      RUNNING_COUNT="-"
    }
  fi

  if [ "$RUNNING_COUNT" = "-" ]; then
    : # 取得失敗時は警告済みのためスキップ
  elif [ "$RUNNING_COUNT" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠ 稼働中インスタンスなし${NC}"
  else
    echo -e "  ${GREEN}✓ 稼働中: ${RUNNING_COUNT}台${NC}"
    [ "$RUNNING_COUNT" -lt "$QUANTITY" ] && echo -e "  ${YELLOW}⚠ 購入数量($QUANTITY)が稼働数($RUNNING_COUNT)を超過${NC}"
  fi

  PURCHASE_QUEUE+=("$LINE_NUM|$REGION|$DB_TYPE|$DB_INSTANCE_CLASS|$ENGINE|$QUANTITY|${DURATION_YEARS}年|$OFFERING_ID")
  RESULTS+=("行 $LINE_NUM: READY - $REGION, $DB_TYPE, $DB_INSTANCE_CLASS, $ENGINE, x$QUANTITY, ${DURATION_YEARS}年, Offering: $OFFERING_ID")

done < <(tr -d '\r' < "$INPUT_FILE")

TOTAL_LINES=$LINE_NUM
DATA_LINES=$((TOTAL_LINES - BLANK_COUNT - COMMENT_COUNT))
READY_COUNT=${#PURCHASE_QUEUE[@]}

echo ""
echo -e "${CYAN}検証結果${NC}"
echo "  総行数: $TOTAL_LINES (データ: $DATA_LINES, 空白: $BLANK_COUNT, コメント: $COMMENT_COUNT)"
echo -e "  購入可能: ${GREEN}$READY_COUNT${NC}, スキップ: ${YELLOW}$SKIP_COUNT${NC}"
echo ""

for result in "${RESULTS[@]}"; do
  [[ "$result" =~ READY ]] && echo -e "${GREEN}✓${NC} $result" || echo -e "${YELLOW}⊘${NC} $result"
done
echo ""

[ "$DRY_RUN" = true ] && echo -e "${CYAN}検証モード: 購入は実行されませんでした${NC}" && exit 0
[ "$READY_COUNT" -eq 0 ] && echo -e "${RED}購入可能な項目がありません${NC}" && exit 1

CURRENT_DATE=$(TZ=Asia/Tokyo date '+%m%d')
CURRENT_HOUR=$(TZ=Asia/Tokyo date '+%H')

if [ "$CURRENT_DATE" != "0401" ] || [ "$CURRENT_HOUR" != "09" ]; then
  echo -e "${YELLOW}⚠ 現在時刻 (JST): $(TZ=Asia/Tokyo date '+%Y/%m/%d %H:%M:%S')${NC}"
  echo -e "${YELLOW}推奨実行時刻: 4/1 09:00:00 - 09:59:59 (JST)${NC}"
  read -t 60 -p "推奨時刻外ですが続行しますか？ (yes/no): " TIME_CONFIRM || true
  [ "${TIME_CONFIRM:-}" != "yes" ] && echo -e "${CYAN}キャンセルしました${NC}" && exit 0
  echo ""
fi

read -t 60 -p "購入を実行しますか？ (yes/no): " FINAL_CONFIRM || true
[ "${FINAL_CONFIRM:-}" != "yes" ] && echo -e "${CYAN}キャンセルしました${NC}" && exit 0

echo ""
echo -e "${YELLOW}購入実行中...${NC}"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0
declare -a PURCHASE_DETAILS=()

for purchase_data in "${PURCHASE_QUEUE[@]}"; do
  IFS='|' read -r LINE_NUM REGION DB_TYPE DB_INSTANCE_CLASS ENGINE QUANTITY DURATION_TEXT OFFERING_ID <<< "$purchase_data"

  echo -e "${CYAN}[行 $LINE_NUM]${NC} 購入中: $REGION, $DB_TYPE, $DB_INSTANCE_CLASS, $ENGINE, x$QUANTITY, $DURATION_TEXT"

  # set -e との競合を回避するため if 文で直接コマンドの成否を判定
  if PURCHASE_RESULT=$(aws rds purchase-reserved-db-instances-offering \
    --region "${REGION}" \
    --reserved-db-instances-offering-id "${OFFERING_ID}" \
    --db-instance-count "${QUANTITY}" \
    --output json 2>&1); then
    RESERVED_ID=$(echo "$PURCHASE_RESULT" | jq -r '.ReservedDBInstance.ReservedDBInstanceId')
    echo -e "${GREEN}[行 $LINE_NUM] ✓ 成功: $RESERVED_ID${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    PURCHASE_DETAILS+=("成功: $REGION, $DB_TYPE, $DB_INSTANCE_CLASS, $ENGINE, x$QUANTITY, $DURATION_TEXT, RI ID: $RESERVED_ID")
  else
    echo -e "${RED}[行 $LINE_NUM] ✗ 失敗${NC}"
    # エラー出力からアカウント固有情報を除去して表示
    echo "$PURCHASE_RESULT" | sed -E 's/[0-9]{12}/[ACCOUNT_ID]/g; s/arn:aws:[^ ]*/[ARN]/g'
    FAIL_COUNT=$((FAIL_COUNT + 1))
    PURCHASE_DETAILS+=("失敗: $REGION, $DB_TYPE, $DB_INSTANCE_CLASS, $ENGINE, x$QUANTITY, $DURATION_TEXT")
  fi
done

echo ""
echo -e "${CYAN}購入結果${NC}"
echo -e "  成功: ${GREEN}$SUCCESS_COUNT${NC}, 失敗: ${RED}$FAIL_COUNT${NC}"
echo ""

# 結果ファイル（アカウントIDを含む）は作成時点から本人のみ読み書き可能にする
umask 077
RESULT_FILE="ri_purchase_result_$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S).txt"
{
  echo "RDS Reserved Instance 購入結果"
  echo "================================"
  echo "実行日時 (JST): $EXECUTION_TIME"
  echo "アカウントID: $ACCOUNT_ID"
  echo "入力ファイル: $INPUT_FILE"
  echo ""
  echo "結果サマリー:"
  echo "  成功: $SUCCESS_COUNT件"
  echo "  失敗: $FAIL_COUNT件"
  echo "  スキップ: $SKIP_COUNT件"
  echo ""
  echo "購入詳細:"
  for detail in "${PURCHASE_DETAILS[@]}"; do echo "  $detail"; done
  echo ""
  echo "検証結果:"
  for result in "${RESULTS[@]}"; do echo "  $result"; done
} > "$RESULT_FILE"
chmod 600 "$RESULT_FILE"

echo -e "${GREEN}✓ 結果ファイル: $RESULT_FILE${NC}"

if [ "$SUCCESS_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✓ Reserved Instance購入が完了しました${NC}"
else
  echo -e "${RED}✗ すべての購入が失敗しました${NC}"
  exit 1
fi
