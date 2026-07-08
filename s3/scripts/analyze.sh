#!/usr/bin/env bash
# analyze.sh — S3 Bucket Lifecycle Readiness Analysis
#
# Reads metadata from S3 (list-objects-v2, CloudWatch metrics, list-multipart-uploads)
# and produces CSV reports for lifecycle policy planning.
#
# ALL OPERATIONS ARE READ-ONLY. No S3 objects are created, modified, or deleted.
#
# Usage:
#   bash scripts/analyze.sh                          # Analyze all buckets
#   bash scripts/analyze.sh --buckets prod-logs      # Single bucket
#   bash scripts/analyze.sh --max-objects 50000      # Lower sample cap
#   bash scripts/analyze.sh --dry-run                # Print commands without executing
#   bash scripts/analyze.sh --region us-east-2       # Override CloudWatch region

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=false
MAX_SAMPLE_OBJECTS=100000
TARGET_BUCKETS=""
CLOUDWATCH_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Read-only S3 bucket analysis for lifecycle policy planning.

Options:
  --buckets B1,B2     Analyze specific buckets (comma-separated)
  --max-objects N     Max objects to sample per bucket (default: $MAX_SAMPLE_OBJECTS)
  --region REGION     CloudWatch metrics region (default: $CLOUDWATCH_REGION)
  --dry-run           Print commands, don't execute
  --help              Show this message

Output files (in ./output/):
  buckets.csv              Bucket inventory (names, regions, creation dates)
  bucket_metrics.csv       Total size + object counts (from CloudWatch)
  bucket_config.csv        Versioning, logging, lifecycle status per bucket
  raw_objects.csv          Sampled object metadata (size, age, storage class)
  size_distribution.csv    Object counts/sizes by size range, per bucket
  age_distribution.csv     Object counts/sizes by age range, per bucket
  storage_class.csv        Object counts/sizes by storage class, per bucket
  mpu_report.csv           Active multipart uploads and orphaned part estimate
  summary.txt              Human-readable summary report

Cost of analysis:
  - list-objects-v2: \$0.005 per 1,000 LIST requests
  - CloudWatch metrics: free
  - get-bucket-location: free
  - list-multipart-uploads: \$0.005 per 1,000 requests
  Total for a typical account: \$0.05–\$0.50
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --buckets)
                TARGET_BUCKETS="$2"
                shift 2
                ;;
            --max-objects)
                MAX_SAMPLE_OBJECTS="$2"
                shift 2
                ;;
            --region)
                CLOUDWATCH_REGION="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

aws_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY-RUN: aws $*" >&2
        echo "{}"
    else
        aws "$@" 2>/dev/null || echo "{}"
    fi
}

aws_cmd_text() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY-RUN: aws $*" >&2
        echo ""
    else
        aws "$@" 2>/dev/null || echo ""
    fi
}

aws_cmd_json_err() {
    local resp
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY-RUN: aws $*" >&2
        echo "{}"
    else
        resp=$(aws "$@" 2>&1) || {
            log_warn "AWS call failed: aws $*  →  ${resp:0:200}"
            echo "{}"
            return
        }
        echo "$resp"
    fi
}

discover_buckets() {
    log_info "Discovering S3 buckets..."

    local buckets_csv="$OUTPUT_DIR/buckets.csv"
    echo "bucket_name,region,creation_date" > "$buckets_csv"

    local all_buckets
    all_buckets=$(aws_cmd s3api list-buckets --no-cli-pager \
        --query "Buckets[].[Name,CreationDate]" --output json)

    if [[ "$all_buckets" == "{}" || "$all_buckets" == "[]" ]]; then
        log_warn "No buckets found."
        echo "" > "$buckets_csv"
        return
    fi

    local total
    total=$(echo "$all_buckets" | jq 'length')
    log_info "Found $(human_number "$total") total buckets in account"

    local i=0
    echo "$all_buckets" | jq -c '.[]' | while IFS= read -r row; do
        local name created
        name=$(echo "$row" | jq -r '.[0]')
        created=$(echo "$row" | jq -r '.[1]')

        if [[ -n "$TARGET_BUCKETS" ]]; then
            IFS=',' read -ra TARGET_ARR <<< "$TARGET_BUCKETS"
            local match=false
            for tb in "${TARGET_ARR[@]}"; do
                [[ "$name" == "$tb" ]] && match=true; break
            done
            if [[ "$match" != "true" ]]; then
                continue
            fi
        fi

        i=$((i + 1))
        local region
        region=$(get_bucket_region "$name")
        log_info "[$i] $name  →  region=$region"

        printf '%s,%s,%s\n' \
            "$(csv_escape "$name")" \
            "$region" \
            "$created" >> "$buckets_csv"
    done

    local discovered
    discovered=$(wc -l < "$buckets_csv" | tr -d ' ')
    discovered=$((discovered - 1))
    log_success "Discovered $discovered buckets matching filters"
}

get_cloudwatch_metrics() {
    log_info "Fetching CloudWatch storage metrics (region: $CLOUDWATCH_REGION)..."

    local metrics_csv="$OUTPUT_DIR/bucket_metrics.csv"
    echo "bucket_name,total_size_bytes,total_size_gb,object_count,estimated_list_cost_usd" > "$metrics_csv"

    local end_time start_time
    end_time=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
    if [[ "$OSTYPE" == "darwin"* ]]; then
        start_time=$(date -u -j -v-7d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    else
        start_time=$(date -u -d "7 days ago" "+%Y-%m-%dT%H:%M:%SZ")
    fi

    tail -n +2 "$OUTPUT_DIR/buckets.csv" 2>/dev/null | while IFS=',' read -r bucket region created; do
        bucket="${bucket//\"/}"

        local size_bytes
        size_bytes=$(aws_cmd_text cloudwatch get-metric-statistics \
            --region "$CLOUDWATCH_REGION" \
            --namespace AWS/S3 \
            --metric-name BucketSizeBytes \
            --dimensions "Name=BucketName,Value=$bucket" "Name=StorageType,Value=StandardStorage" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --period 86400 \
            --statistics Average \
            --no-cli-pager \
            --query "sort_by(Datapoints,&Timestamp)[-1].Average" \
            --output text)

        local obj_count
        obj_count=$(aws_cmd_text cloudwatch get-metric-statistics \
            --region "$CLOUDWATCH_REGION" \
            --namespace AWS/S3 \
            --metric-name NumberOfObjects \
            --dimensions "Name=BucketName,Value=$bucket" "Name=StorageType,Value=AllStorageTypes" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --period 86400 \
            --statistics Average \
            --no-cli-pager \
            --query "sort_by(Datapoints,&Timestamp)[-1].Average" \
            --output text)

        if [[ -z "$size_bytes" || "$size_bytes" == "None" || "$size_bytes" == "null" ]]; then
            size_bytes=0
        fi
        if [[ -z "$obj_count" || "$obj_count" == "None" || "$obj_count" == "null" ]]; then
            obj_count=0
        fi

        local size_gb
        size_gb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.2f", b / 1073741824 }')
        local list_cost
        list_cost=$(awk -v o="$obj_count" -v m=5000 'BEGIN { printf "%.4f", (o / m) * 0.005 }')

        printf '%s,%s,%s,%s,%s\n' \
            "$(csv_escape "$bucket")" \
            "$size_bytes" \
            "$size_gb" \
            "${obj_count%.*}" \
            "$list_cost" >> "$metrics_csv"

        local hsize hcount
        hsize=$(human_size "${size_bytes%.*}")
        hcount=$(human_number "${obj_count%.*}")
        log_info "  $bucket  →  $hsize  /  $hcount objects"
    done

    log_success "CloudWatch metrics collected"
}

get_bucket_configs() {
    log_info "Fetching bucket configurations..."

    local config_csv="$OUTPUT_DIR/bucket_config.csv"
    echo "bucket_name,versioning,has_lifecycle_rules,lifecycle_rule_count" > "$config_csv"

    tail -n +2 "$OUTPUT_DIR/buckets.csv" 2>/dev/null | while IFS=',' read -r bucket region created; do
        bucket="${bucket//\"/}"

        local ver lifecycle rule_count
        ver=$(get_bucket_versioning "$bucket" "$region")
        lifecycle=$(get_bucket_lifecycle "$bucket" "$region")
        rule_count=$(echo "$lifecycle" | jq 'length' 2>/dev/null || echo "0")
        local has_rules="false"
        if [[ "$rule_count" -gt 0 ]]; then
            has_rules="true"
        fi

        printf '%s,%s,%s,%s\n' \
            "$(csv_escape "$bucket")" \
            "${ver:-Suspended}" \
            "$has_rules" \
            "$rule_count" >> "$config_csv"
    done

    log_success "Bucket configurations collected"
}

sample_objects_for_bucket() {
    local bucket=$1 region=$2 max_objects=$3 raw_csv=$4

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY-RUN: Would list objects in $bucket (region=$region, max=$max_objects)" >&2
        return
    fi

    local next_token="" page=0 collected=0

    while true; do
        page=$((page + 1))
        local resp
        if [[ -z "$next_token" ]]; then
            resp=$(aws s3api list-objects-v2 \
                --bucket "$bucket" --region "$region" \
                --max-items 5000 --no-cli-pager \
                --query "{Contents: Contents[].{Size: Size, StorageClass: StorageClass, LastModified: LastModified}, NextToken: NextContinuationToken}" \
                --output json 2>/dev/null) || {
                log_warn "  list-objects-v2 failed for $bucket (page $page)"
                break
            }
        else
            resp=$(aws s3api list-objects-v2 \
                --bucket "$bucket" --region "$region" \
                --max-items 5000 --no-cli-pager \
                --starting-token "$next_token" \
                --query "{Contents: Contents[].{Size: Size, StorageClass: StorageClass, LastModified: LastModified}, NextToken: NextContinuationToken}" \
                --output json 2>/dev/null) || {
                log_warn "  list-objects-v2 failed for $bucket (page $page)"
                break
            }
        fi

        next_token=$(echo "$resp" | jq -r '.NextToken // ""')
        local page_count
        page_count=$(echo "$resp" | jq '[.Contents[]?] | length' 2>/dev/null || echo "0")

        if [[ "$page_count" -eq 0 ]]; then
            break
        fi

        local now_epoch
        if [[ "$OSTYPE" == "darwin"* ]]; then
            now_epoch=$(date "+%s")
        else
            now_epoch=$(date "+%s")
        fi

        echo "$resp" | jq -c '.Contents[]?' | while IFS= read -r obj; do
            local size sc lm age_days
            size=$(echo "$obj" | jq -r '.Size // 0')
            sc=$(echo "$obj" | jq -r '.StorageClass // "STANDARD"')
            lm=$(echo "$obj" | jq -r '.LastModified // ""')

            if [[ -n "$lm" && "$lm" != "null" ]]; then
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    local epoch
                    epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${lm%%.*}" "+%s" 2>/dev/null || echo "$now_epoch")
                    age_days=$(( (now_epoch - epoch) / 86400 ))
                else
                    local epoch
                    epoch=$(date -d "$lm" "+%s" 2>/dev/null || echo "$now_epoch")
                    age_days=$(( (now_epoch - epoch) / 86400 ))
                fi
            else
                age_days=0
            fi

            printf '%s,%s,%s,%s\n' "$(csv_escape "$bucket")" "$size" "$age_days" "$sc" >> "$raw_csv"
        done

        collected=$((collected + page_count))
        if [[ $((page % 20)) -eq 0 ]]; then
            log_info "  $bucket: processed $(human_number "$collected") objects..."
        fi

        if [[ "$collected" -ge "$max_objects" ]]; then
            break
        fi
        if [[ -z "$next_token" ]]; then
            break
        fi
    done
}

collect_object_samples() {
    log_info "Sampling object metadata..."

    local raw_csv="$OUTPUT_DIR/raw_objects.csv"
    echo "bucket_name,size_bytes,age_days,storage_class" > "$raw_csv"

    tail -n +2 "$OUTPUT_DIR/bucket_metrics.csv" 2>/dev/null | while IFS=',' read -r bucket size_bytes size_gb count_str cost; do
        bucket="${bucket//\"/}"
        local obj_count=${count_str%.*}

        if [[ "$obj_count" -eq 0 ]]; then
            log_info "  $bucket: empty, skipping"
            continue
        fi

        local region
        region=$(grep "^\"$bucket\"," "$OUTPUT_DIR/buckets.csv" 2>/dev/null | cut -d',' -f2 || echo "us-east-1")
        region="${region//\"/}"

        local sample_size=$MAX_SAMPLE_OBJECTS
        local mode="full"
        if [[ "$obj_count" -gt "$MAX_SAMPLE_OBJECTS" ]]; then
            mode="sample"
        fi

        log_info "  $bucket: $(human_number "$obj_count") objects → $mode mode (max $sample_size)"
        sample_objects_for_bucket "$bucket" "$region" "$sample_size" "$raw_csv"

        local actual
        actual=$(grep -c "^\"$bucket\"," "$raw_csv" 2>/dev/null || echo "0")
        log_info "  $bucket: collected $actual object samples"
    done

    log_success "Object sampling complete"
}

generate_distributions() {
    log_info "Generating distribution reports..."

    local raw_csv="$OUTPUT_DIR/raw_objects.csv"

    if [[ ! -s "$raw_csv" ]] || [[ $(wc -l < "$raw_csv") -le 1 ]]; then
        log_warn "No object data to generate distributions from"
        return
    fi

    local size_csv="$OUTPUT_DIR/size_distribution.csv"
    local age_csv="$OUTPUT_DIR/age_distribution.csv"
    local class_csv="$OUTPUT_DIR/storage_class.csv"

    echo "bucket_name,size_range,object_count,total_size_bytes,total_size_gb,pct_objects,pct_storage" > "$size_csv"
    echo "bucket_name,age_range,object_count,total_size_bytes,total_size_gb,pct_objects,pct_storage" > "$age_csv"
    echo "bucket_name,storage_class,object_count,total_size_bytes,total_size_gb,pct_objects,pct_storage" > "$class_csv"

    awk -F',' '
    BEGIN { OFS = "," }

    NR == 1 { next }

    function size_label(s) {
        if (s < 1024)        return "<1KB"
        if (s < 131072)      return "1KB-128KB"
        if (s < 1048576)     return "128KB-1MB"
        if (s < 10485760)    return "1MB-10MB"
        if (s < 104857600)   return "10MB-100MB"
        return ">100MB"
    }

    function age_label(d) {
        if (d < 30)   return "0-30d"
        if (d < 90)   return "30-90d"
        if (d < 180)  return "90-180d"
        if (d < 365)  return "180-365d"
        if (d < 1095) return "1-3yr"
        return "3yr+"
    }

    {
        bucket = $1
        gsub(/^"/, "", bucket); gsub(/"$/, "", bucket)
        size   = $2 + 0
        age    = $3 + 0
        cls    = $4

        gsub(/^"/, "", cls); gsub(/"$/, "", cls)
        if (cls == "") cls = "STANDARD"

        key = bucket

        # Size distribution
        sl = size_label(size)
        s_counts[key SUBSEP sl]++
        s_bytes[key SUBSEP sl] += size

        # Age distribution
        al = age_label(age)
        a_counts[key SUBSEP al]++
        a_bytes[key SUBSEP al] += size

        # Storage class
        c_counts[key SUBSEP cls]++
        c_bytes[key SUBSEP cls] += size
    }

    END {
        # Compute bucket totals
        for (k in s_counts) {
            split(k, parts, SUBSEP)
            b = parts[1]
            b_total_objects[b] += s_counts[k]
            b_total_bytes[b]   += s_bytes[k]
        }

        # Size distribution output
        PROCINFO["sorted_in"] = "@ind_str_asc"
        PROCINFO["sorted_in"] = "@ind_str_asc"

        for (k in s_counts) {
            split(k, parts, SUBSEP)
            b  = parts[1]
            sl = parts[2]
            cnt = s_counts[k]
            bts = s_bytes[k]
            gb  = bts / 1073741824
            pct_o = (b_total_objects[b] > 0) ? (cnt / b_total_objects[b]) * 100 : 0
            pct_s = (b_total_bytes[b] > 0)   ? (bts / b_total_bytes[b]) * 100   : 0
            printf "%s,%s,%d,%d,%.4f,%.2f,%.2f\n", b, sl, cnt, bts, gb, pct_o, pct_s > "'"$size_csv"'"
        }

        for (k in a_counts) {
            split(k, parts, SUBSEP)
            b  = parts[1]
            al = parts[2]
            cnt = a_counts[k]
            bts = a_bytes[k]
            gb  = bts / 1073741824
            pct_o = (b_total_objects[b] > 0) ? (cnt / b_total_objects[b]) * 100 : 0
            pct_s = (b_total_bytes[b] > 0)   ? (bts / b_total_bytes[b]) * 100   : 0
            printf "%s,%s,%d,%d,%.4f,%.2f,%.2f\n", b, al, cnt, bts, gb, pct_o, pct_s > "'"$age_csv"'"
        }

        for (k in c_counts) {
            split(k, parts, SUBSEP)
            b   = parts[1]
            cls = parts[2]
            cnt = c_counts[k]
            bts = c_bytes[k]
            gb  = bts / 1073741824
            pct_o = (b_total_objects[b] > 0) ? (cnt / b_total_objects[b]) * 100 : 0
            pct_s = (b_total_bytes[b] > 0)   ? (bts / b_total_bytes[b]) * 100   : 0
            printf "%s,%s,%d,%d,%.4f,%.2f,%.2f\n", b, cls, cnt, bts, gb, pct_o, pct_s > "'"$class_csv"'"
        }
    }
    ' "$raw_csv"

    log_success "Distribution CSVs generated"
}

check_multipart_uploads() {
    log_info "Checking for active multipart uploads..."

    local mpu_csv="$OUTPUT_DIR/mpu_report.csv"
    echo "bucket_name,active_uploads,estimated_orphaned_count,estimated_orphaned_size_gb,oldest_upload_age_days,sample_upload_ids" > "$mpu_csv"

    tail -n +2 "$OUTPUT_DIR/buckets.csv" 2>/dev/null | while IFS=',' read -r bucket region created; do
        bucket="${bucket//\"/}"

        local resp count est_orphaned est_size oldest sample_ids

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "DRY-RUN: check MPU for $bucket" >&2
            printf '%s,0,0,0,0,\n' "$(csv_escape "$bucket")" >> "$mpu_csv"
            continue
        fi

        resp=$(aws s3api list-multipart-uploads \
            --bucket "$bucket" --region "$region" \
            --no-cli-pager \
            --query "{Uploads: Uploads[].{Key: Key, Initiated: Initiated, UploadId: UploadId}}" \
            --output json 2>/dev/null) || resp="{}"

        count=$(echo "$resp" | jq '[.Uploads[]?] | length' 2>/dev/null || echo "0")

        if [[ "$count" -eq 0 ]]; then
            printf '%s,0,0,0.0000,0,\n' "$(csv_escape "$bucket")" >> "$mpu_csv"
            continue
        fi

        est_orphaned=$(awk -v c="$count" 'BEGIN { printf "%.0f", c * 0.85 }')
        est_size="0.0000"

        oldest=$(echo "$resp" | jq -r '[.Uploads[]?.Initiated] | sort | .[0] // ""')
        local oldest_age=0
        if [[ -n "$oldest" && "$oldest" != "null" ]]; then
            oldest_age=$(compute_age_days "$oldest")
        fi

        sample_ids=$(echo "$resp" | jq -r '[.Uploads[]?.UploadId] | .[0:3] | join(" | ")' 2>/dev/null || echo "")

        printf '%s,%s,%s,%s,%s,%s\n' \
            "$(csv_escape "$bucket")" \
            "$count" \
            "$est_orphaned" \
            "$est_size" \
            "$oldest_age" \
            "$(csv_escape "$sample_ids")" >> "$mpu_csv"

        log_warn "  $bucket: $count active MPUs (oldest: ${oldest_age}d ago)"
    done

    log_success "Multipart upload report generated"
}

generate_summary() {
    log_info "Generating summary report..."

    local summary="$OUTPUT_DIR/summary.txt"
    local line="══════════════════════════════════════════════════════════════════"

    {
        echo "$line"
        echo "    S3 Lifecycle Analysis Report"
        echo "    Generated: $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "    Account: $(aws_cmd sts get-caller-identity --no-cli-pager --query Arn --output text)"
        echo "$line"
        echo ""

        local total_buckets total_size total_objects total_mpus
        total_buckets=0; total_size=0; total_objects=0; total_mpus=0

        if [[ -s "$OUTPUT_DIR/bucket_metrics.csv" ]]; then
            tail -n +2 "$OUTPUT_DIR/bucket_metrics.csv" | while IFS=',' read -r b s g c cost; do
                true
            done
        fi

        echo "BUCKET OVERVIEW"
        echo "──────────────────────────────────────────────────────────────────"
        awk -F',' '
        NR == 1 { next }
        {
            total_buckets++
            total_size += $3
            total_objects += $4 + 0
        }
        END {
            printf "  Total buckets:      %d\n", total_buckets
            printf "  Total storage:      %.2f GB\n", total_size
            printf "  Total objects:      %d\n", total_objects
        }
        ' "$OUTPUT_DIR/bucket_metrics.csv"
        echo ""

        if [[ -s "$OUTPUT_DIR/bucket_metrics.csv" ]]; then
            echo "TOP BUCKETS BY SIZE"
            echo "──────────────────────────────────────────────────────────────────"
            sort -t',' -k3 -gr "$OUTPUT_DIR/bucket_metrics.csv" 2>/dev/null | head -5 | \
            awk -F',' 'NR>=1 { gsub(/"/, "", $1); printf "  %-35s  %8s GB  %8s objects\n", $1, $3, $4 }'
            echo ""
        fi

        echo "SIZE DISTRIBUTION (all buckets combined)"
        echo "──────────────────────────────────────────────────────────────────"
        if [[ -s "$OUTPUT_DIR/size_distribution.csv" ]]; then
            awk -F',' '
            NR == 1 { next }
            {
                key = $2
                counts[key]   += $3
                bytes[key]    += $4
                total_objects += $3
                total_bytes   += $4
            }
            END {
                for (k in counts) {
                    pct_obj = (total_objects > 0) ? (counts[k] / total_objects) * 100 : 0
                    pct_byt = (total_bytes   > 0) ? (bytes[k]   / total_bytes)   * 100 : 0
                    printf "  %-15s  %6.1f%% of objects  %6.1f%% of storage\n", k, pct_obj, pct_byt
                }
            }
            ' "$OUTPUT_DIR/size_distribution.csv" | sort
        else
            echo "  (no data)"
        fi
        echo ""

        echo "AGE DISTRIBUTION (all buckets combined)"
        echo "──────────────────────────────────────────────────────────────────"
        if [[ -s "$OUTPUT_DIR/age_distribution.csv" ]]; then
            awk -F',' '
            NR == 1 { next }
            {
                key = $2
                counts[key]   += $3
                bytes[key]    += $4
                total_objects += $3
                total_bytes   += $4
            }
            END {
                for (k in counts) {
                    pct_obj = (total_objects > 0) ? (counts[k] / total_objects) * 100 : 0
                    pct_byt = (total_bytes   > 0) ? (bytes[k]   / total_bytes)   * 100 : 0
                    printf "  %-10s  %6.1f%% of objects  %6.1f%% of storage\n", k, pct_obj, pct_byt
                }
            }
            ' "$OUTPUT_DIR/age_distribution.csv" | sort -t'-' -k1 -n
        else
            echo "  (no data)"
        fi
        echo ""

        echo "STORAGE CLASS BREAKDOWN"
        echo "──────────────────────────────────────────────────────────────────"
        if [[ -s "$OUTPUT_DIR/storage_class.csv" ]]; then
            awk -F',' '
            NR == 1 { next }
            {
                key = $2
                counts[key]   += $3
                bytes[key]    += $4
                total_objects += $3
                total_bytes   += $4
            }
            END {
                for (k in counts) {
                    pct_obj = (total_objects > 0) ? (counts[k] / total_objects) * 100 : 0
                    pct_byt = (total_bytes   > 0) ? (bytes[k]   / total_bytes)   * 100 : 0
                    gb = bytes[k] / 1073741824
                    printf "  %-30s  %8d objects  %6.1f GB  (%5.1f%%)\n", k, counts[k], gb, pct_byt
                }
            }
            ' "$OUTPUT_DIR/storage_class.csv"
        else
            echo "  (no data)"
        fi
        echo ""

        echo "INTELLIGENT-TIERING PROJECTION"
        echo "──────────────────────────────────────────────────────────────────"
        if [[ -s "$OUTPUT_DIR/bucket_metrics.csv" ]]; then
            awk -F',' '
            NR == 1 { next }
            { total_objects += $4 + 0; total_gb += $3 }
            END {
                monitoring_fee = (total_objects / 1000) * 0.0025
                printf "  Monitoring fee:     ~$%.2f/month (%.0f objects)\n", monitoring_fee, total_objects
                printf "  Current est. cost:  ~$%.2f/month (Standard @ $0.023/GB)\n", total_gb * 0.023

                infreq_gb = total_gb * 0.50
                save_infreq = infreq_gb * (0.023 - 0.0125)
                printf "  Est. savings:       ~$%.2f/month (if 50%% transitions to Infrequent)\n", save_infreq - monitoring_fee
                printf "  Note: actual savings depend on access patterns — run Storage Class Analysis for precision.\n"
            }
            ' "$OUTPUT_DIR/bucket_metrics.csv"
        else
            echo "  (no data)"
        fi
        echo ""

        if [[ -s "$OUTPUT_DIR/mpu_report.csv" ]]; then
            echo "MULTIPART UPLOAD WARNINGS"
            echo "──────────────────────────────────────────────────────────────────"
            awk -F',' '
            NR == 1 { next }
            $2 + 0 > 0 {
                gsub(/"/, "", $1)
                printf "  %-35s  %5d active MPUs  oldest: %s d\n", $1, $2, $5
                mpu_total += $2
            }
            END {
                if (mpu_total > 0) {
                    printf "\n  Total active MPUs across all buckets: %d\n", mpu_total
                    printf "  Orphaned MPUs consume storage at Standard rates indefinitely.\n"
                    printf "  Consider adding an abort-incomplete-multipart-upload lifecycle rule.\n"
                }
            }
            ' "$OUTPUT_DIR/mpu_report.csv"
        fi
        echo ""

        echo "BUCKET CONFIGURATION STATUS"
        echo "──────────────────────────────────────────────────────────────────"
        if [[ -s "$OUTPUT_DIR/bucket_config.csv" ]]; then
            awk -F',' '
            NR == 1 { next }
            {
                gsub(/"/, "", $1)
                has_lc = ($3 == "true") ? "✓" : "✗"
                printf "  %-35s  versioning: %-10s  lifecycle: %s (%s rules)\n", $1, $2, has_lc, $4
            }
            ' "$OUTPUT_DIR/bucket_config.csv"
        fi
        echo ""

        local has_warnings=false
        if [[ -s "$OUTPUT_DIR/size_distribution.csv" ]]; then
            local small128_pct
            small128_pct=$(awk -F',' '
                NR==1{next}
                $2 ~ /^<1KB$|^1KB-128KB$/ {sc+=$3; tc+=$3}
                {tc+=$3}
                END { if(tc>0) printf "%.1f", (sc/tc)*100; else print "0" }
            ' "$OUTPUT_DIR/size_distribution.csv")

            if [[ -n "$small128_pct" ]] && awk "BEGIN { exit ($small128_pct > 30) ? 0 : 1 }"; then
                has_warnings=true
            fi
        fi

        if [[ "$has_warnings" == "true" ]]; then
            echo "WARNINGS & RECOMMENDATIONS"
            echo "──────────────────────────────────────────────────────────────────"
            if [[ -n "${small128_pct-}" ]] && awk "BEGIN { exit ($small128_pct > 30) ? 0 : 1 }"; then
                echo "  • ${small128_pct}% of objects are <128 KB"
                echo "    These stay in Frequent Access tier under Intelligent-Tiering (no penalty, but no savings)."
            fi
            if [[ -s "$OUTPUT_DIR/mpu_report.csv" ]]; then
                local mpu_count
                mpu_count=$(awk -F',' 'NR>1{sum+=$2} END{print sum+0}' "$OUTPUT_DIR/mpu_report.csv")
                if [[ "$mpu_count" -gt 0 ]]; then
                    echo "  • $mpu_count active multipart uploads found — potential cost leak."
                    echo "    Add lifecycle rule: AbortIncompleteMultipartUpload after 7 days."
                fi
            fi
        fi

        echo "$line"
        echo "    Analysis complete. Review output/ CSVs for detailed breakdown."
        echo "    Next step: verify access patterns, then apply Intelligent-Tiering lifecycle rules."
        echo "$line"

    } > "$summary"

    cat "$summary"
    echo ""
    log_success "Summary written to $summary"
}

cleanup_on_interrupt() {
    log_warn "Interrupted. Partial results may be in $OUTPUT_DIR"
    exit 1
}

main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}S3 Lifecycle Analysis${NC}"
    echo "All operations are read-only — no S3 objects will be modified."
    echo ""

    check_prerequisites
    init_output_dir

    trap cleanup_on_interrupt INT TERM

    discover_buckets

    local bucket_count
    bucket_count=$(tail -n +2 "$OUTPUT_DIR/buckets.csv" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$bucket_count" -eq 0 ]]; then
        log_error "No buckets to analyze. Check --buckets filter or AWS credentials."
        exit 1
    fi

    get_cloudwatch_metrics
    get_bucket_configs
    collect_object_samples
    generate_distributions
    check_multipart_uploads
    generate_summary

    echo ""
    log_success "Done. All output in: $OUTPUT_DIR/"
    echo "  $(ls "$OUTPUT_DIR/"*.csv 2>/dev/null | wc -l | tr -d ' ') CSV files generated"
}

main "$@"
