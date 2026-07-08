#!/usr/bin/env bash
# common.sh — Shared utilities for S3 analysis scripts
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OUTPUT_DIR=""

log_info()    { echo -e "[${CYAN}INFO${NC}]  $(date '+%H:%M:%S') $*" >&2; }
log_warn()    { echo -e "[${YELLOW}WARN${NC}]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo -e "[${RED}ERROR${NC}] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo -e "[${GREEN}OK${NC}]    $(date '+%H:%M:%S') $*" >&2; }

csv_escape() {
    local val="${1-}"
    val="${val//$'\n'/ }"
    val="${val//$'\r'/}"
    if [[ "$val" == *[,]* || "$val" == *'"'* ]]; then
        val="${val//\"/\"\"}"
        printf '"%s"' "$val"
    else
        printf '%s' "$val"
    fi
}

human_size() {
    local bytes=${1:-0}
    if [[ -z "$bytes" || "$bytes" == "null" || "$bytes" -le 0 ]]; then
        echo "0 B"; return
    fi
    if (( bytes < 1024 )); then
        echo "${bytes} B"
    elif (( bytes < 1048576 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f KB", b / 1024 }'
    elif (( bytes < 1073741824 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b / 1048576 }'
    elif (( bytes < 1099511627776 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f GB", b / 1073741824 }'
    else
        awk -v b="$bytes" 'BEGIN { printf "%.2f TB", b / 1099511627776 }'
    fi
}

human_number() {
    local n=${1:-0}
    if (( n < 1000 )); then
        echo "$n"
    elif (( n < 1000000 )); then
        awk -v n="$n" 'BEGIN { printf "%.1fK", n / 1000 }'
    else
        awk -v n="$n" 'BEGIN { printf "%.2fM", n / 1000000 }'
    fi
}

size_bucket_label() {
    local size=$1
    if (( size < 1024 )); then
        echo "<1KB"
    elif (( size < 131072 )); then
        echo "1KB-128KB"
    elif (( size < 1048576 )); then
        echo "128KB-1MB"
    elif (( size < 10485760 )); then
        echo "1MB-10MB"
    elif (( size < 104857600 )); then
        echo "10MB-100MB"
    else
        echo ">100MB"
    fi
}

age_bucket_label() {
    local days=$1
    if (( days < 30 )); then
        echo "0-30d"
    elif (( days < 90 )); then
        echo "30-90d"
    elif (( days < 180 )); then
        echo "90-180d"
    elif (( days < 365 )); then
        echo "180-365d"
    elif (( days < 1095 )); then
        echo "1-3yr"
    else
        echo "3yr+"
    fi
}

compute_age_days() {
    local iso_date="$1"
    local epoch now
    if [[ "$OSTYPE" == "darwin"* ]]; then
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${iso_date%%.*}" "+%s" 2>/dev/null || echo "0")
        now=$(date "+%s")
    else
        epoch=$(date -d "$iso_date" "+%s" 2>/dev/null || echo "0")
        now=$(date "+%s")
    fi
    echo $(( (now - epoch) / 86400 ))
}

check_prerequisites() {
    local missing=()

    if ! command -v aws &>/dev/null; then
        missing+=("aws CLI — https://aws.amazon.com/cli/")
    fi
    if ! command -v jq &>/dev/null; then
        missing+=("jq — brew install jq / apt install jq")
    fi
    if ! command -v awk &>/dev/null; then
        missing+=("awk (should be pre-installed on macOS/Linux)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools:"
        for tool in "${missing[@]}"; do
            echo "  - $tool" >&2
        done
        exit 1
    fi

    if ! aws sts get-caller-identity --no-cli-pager &>/dev/null; then
        log_error "AWS credentials not configured or expired."
        log_error "Run: aws configure   or   export AWS_PROFILE=your-profile"
        exit 1
    fi

    local identity
    identity=$(aws sts get-caller-identity --no-cli-pager --query "Arn" --output text 2>/dev/null)
    log_success "Authenticated as: $identity"
}

init_output_dir() {
    OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR:-.}/../output}"
    mkdir -p "$OUTPUT_DIR"
    log_info "Output directory: $OUTPUT_DIR"
}

get_bucket_region() {
    local bucket=$1
    local region
    region=$(aws s3api get-bucket-location --bucket "$bucket" --no-cli-pager \
        --query "LocationConstraint" --output text 2>/dev/null || echo "us-east-1")
    if [[ "$region" == "None" || "$region" == "null" || -z "$region" ]]; then
        region="us-east-1"
    fi
    echo "$region"
}

get_bucket_lifecycle() {
    local bucket=$1 region=$2
    aws s3api get-bucket-lifecycle-configuration \
        --bucket "$bucket" --region "$region" --no-cli-pager \
        --query "Rules[].{Id: Id, Status: Status}" \
        --output json 2>/dev/null || echo "[]"
}

get_bucket_versioning() {
    local bucket=$1 region=$2
    local status
    status=$(aws s3api get-bucket-versioning \
        --bucket "$bucket" --region "$region" --no-cli-pager \
        --query "Status" --output text 2>/dev/null || echo "Suspended")
    echo "$status"
}
