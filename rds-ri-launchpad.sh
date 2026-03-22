#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# RDS/Aurora Reserved Instance 一括購入スクリプト v3.6 (Security Reviewed)

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

# CSVのengine値からAPI用のproduct-description値へ変換
# APIフィルタで受け付ける値とレスポンスに返る値が異なるため、マッピングが必要
# 例: CSV "oracle-se2" → API filter "oracle-se2" → レスポンス "oracle-se2(li)"
#     CSV "oracle-se2-byol" → API filter "oracle-se2-byol" → レスポンス "oracle-se2 (byol)"
map_product_description() {
  local engine=$1
  case "$engine" in
    aurora-mysql|aurora-postgresql|mysql|postgresql|mariadb) echo "$engine" ;;
    oracle-se2|oracle-ee|sqlserver-ex|sqlserver-ee|sqlserver-se|sqlserver-web) echo "$engine" ;;
    oracle-se2-byol|oracle-ee-byol) echo "$engine" ;;
    sqlserver-ee-byol|sqlserver-se-byol) echo "$engine" ;;
    custom-oracle-ee-byol|custom-oracle-se2-byol) echo "$engine" ;;
    custom-sqlserver-ee|custom-sqlserver-se|custom-sqlserver-web) echo "$engine" ;;
    custom-sqlserver-ee-byol|custom-sqlserver-se-byol) echo "$engine" ;;
    db2-ae|db2-ae-byol|db2-se|db2-se-byol) echo "$engine" ;;
    *) echo "" ;;  # 未知のエンジンは空文字を返す（validate_lineで排除済みだが防御的に）
  esac
}

validate_line() {
  local region=$1 db_type=$2 instance_class=$3 engine=$4 payment=$5 quantity=$6 duration_years=$7

  [[ ! "$instance_class" =~ ^db\.[a-z0-9]+\.[a-z0-9]+$ ]] && echo "インスタンスクラス形式が無効: $instance_class" && return 1

  # 対象環境で利用されているエンジンのみ許可（意図的な制限）
  case "$engine" in
    aurora-mysql|aurora-postgresql|mysql|postgresql|mariadb) ;;
    oracle-se2|oracle-se2-byol|oracle-ee|oracle-ee-byol) ;;
    custom-oracle-ee-byol|custom-oracle-se2-byol) ;;
    sqlserver-ex|sqlserver-ee|sqlserver-se|sqlserver-web) ;;
    sqlserver-ee-byol|sqlserver-se-byol) ;;
    custom-sqlserver-ee|custom-sqlserver-se|custom-sqlserver-web) ;;
    custom-sqlserver-ee-byol|custom-sqlserver-se-byol) ;;
    db2-ae|db2-ae-byol|db2-se|db2-se-byol) ;;
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

# ロックディレクトリによる並行実行防止
# 1時間以上経過したロックは古いプロセスの残存とみなし自動解除
LOCK_DIR="/tmp/rds_ri_purchase_lock"
if [ -d "$LOCK_DIR" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo "0") ))
  if [ "$LOCK_AGE" -gt 3600 ]; then
    echo -e "${YELLOW}⚠ 古いロックファイルを自動解除しました（${LOCK_AGE}秒経過）${NC}"
    rm -rf "$LOCK_DIR"
  fi
fi
! mkdir "$LOCK_DIR" 2>/dev/null && echo -e "${RED}エラー: 既に実行中です${NC}" && exit 1
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

echo -e "${YELLOW}サンプルスクリプト - 使用は自己責任でお願いします${NC}\n"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EXECUTION_TIME=$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')

echo -e "${CYAN}RDS/Aurora RI 購入スクリプト v3.6${NC}"
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

  if ! VALIDATION_ERROR=$(validate_line "$REGION" "$DB_TYPE" "$DB_INSTANCE_CLASS" "$ENGINE" "$PAYMENT_OPTION" "$QUANTITY" "$DURATION_YEARS" 2>&1); then
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
    [ "$MULTI_AZ_INPUT" = "yes" ] && MULTI_AZ_FLAG="--multi-az" && MULTI_AZ_BOOL="true" || MULTI_AZ_FLAG="--no-multi-az" && MULTI_AZ_BOOL="false"
  fi

  # CSVのengine値からAPI用のproduct-description値へ変換
  PRODUCT_DESC=$(map_product_description "$ENGINE")

  # map_product_descriptionが空文字を返した場合はスキップ（防御的チェック）
  if [ -z "$PRODUCT_DESC" ]; then
    echo -e "  ${RED}✗ エンジン名のマッピングに失敗: $ENGINE${NC}"
    RESULTS+=("行 $LINE_NUM: SKIP - エンジン名マッピング失敗: $ENGINE")
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # MULTI_AZ_FLAG は意図的にクォートなし（--multi-az / --no-multi-az をフラグとして展開するため）
  # offering-type は防御的にハードコード（validate_lineで No Upfront 以外は既に排除済みだが、
  # 万が一バリデーションにバグがあっても意図しない前払い購入を防止するため）
  # 全検索条件を指定しているため返されるオファリングは通常1件に絞り込まれる（[0]で問題なし）
  OFFERINGS=$(aws rds describe-reserved-db-instances-offerings \
    --region "${REGION}" \
    --db-instance-class "${DB_INSTANCE_CLASS}" \
    --product-description "${PRODUCT_DESC}" \
    ${MULTI_AZ_FLAG} \
    --duration "${DURATION}" \
    --offering-type "No Upfront" \
    --query 'ReservedDBInstancesOfferings[0].[ReservedDBInstancesOfferingId,FixedPrice,RecurringCharges[0].RecurringChargeAmount,CurrencyCode]' \
    --output json 2>&1) || {
    if echo "$OFFERINGS" | grep -qE 'ExpiredToken|AccessDenied|AuthFailure'; then
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

  OFFERING_ID=$(echo "$OFFERINGS" | jq -r '.[0]')
  FIXED_PRICE=$(echo "$OFFERINGS" | jq -r '.[1]')
  RECURRING_PRICE=$(echo "$OFFERINGS" | jq -r '.[2]')
  CURRENCY=$(echo "$OFFERINGS" | jq -r '.[3]')

  echo -e "  ${GREEN}✓ Offering: $OFFERING_ID (前払: $FIXED_PRICE $CURRENCY, 時間単価: $RECURRING_PRICE $CURRENCY)${NC}"

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
    # MultiAZはbool型のため、JMESPathのバッククォートリテラル（文字列）とは一致しない
    # to_string()で文字列に変換してから比較する
    # AWS CLI v2のクライアントサイド自動ページネーションにより全件取得される
    RUNNING_COUNT=$(aws rds describe-db-instances --region "${REGION}" \
      --query "DBInstances[?DBInstanceClass==\`${DB_INSTANCE_CLASS}\` && Engine==\`${SEARCH_ENGINE}\` && to_string(MultiAZ)==\`${MULTI_AZ_BOOL}\` && DBInstanceStatus==\`available\`] | length(@)" \
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
