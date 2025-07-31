#!/bin/bash

# Script to extract CloudLab machine hostnames from manifest.xml
# Usage: ./extract-machines.sh [manifest.xml] [output_file]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to extract hostnames using different methods
extract_hostnames() {
    local manifest_file="$1"
    local method="$2"
    
    case "$method" in
        "xmllint")
            # Use xmllint (part of libxml2-utils) - most reliable
            xmllint --xpath "//host/@name" "$manifest_file" 2>/dev/null | \
                sed 's/name="//g' | sed 's/"//g' | tr ' ' '\n' | grep -v '^$'
            ;;
        "grep")
            # Use grep - fallback method
            grep '<host name=' "$manifest_file" | \
                sed 's/.*<host name="//g' | \
                sed 's/".*//g'
            ;;
        "awk")
            # Use awk - another fallback
            awk -F'"' '/<host name=/ {print $2}' "$manifest_file"
            ;;
        "python")
            # Use Python if available
            python3 -c "
import xml.etree.ElementTree as ET
import sys

try:
    tree = ET.parse('$manifest_file')
    root = tree.getroot()
    
    # Find all host elements
    for host in root.findall('.//host'):
        hostname = host.get('name')
        if hostname:
            print(hostname)
except Exception as e:
    sys.exit(1)
"
            ;;
    esac
}

# Function to validate extracted hostnames
validate_hostnames() {
    local hostnames=("$@")
    local valid_count=0
    
    for hostname in "${hostnames[@]}"; do
        # Check if hostname looks like a CloudLab hostname
        if [[ "$hostname" =~ ^node[0-9]+\..+\.cloudlab\.us$ ]]; then
            ((valid_count++))
        else
            warning "Hostname '$hostname' doesn't match expected CloudLab pattern"
        fi
    done
    
    log "Validated $valid_count/${#hostnames[@]} hostnames"
    return 0
}

# Function to extract machine information
extract_machine_info() {
    local manifest_file="$1"
    local output_format="$2"
    
    log "Extracting machine information from $manifest_file"
    
    # Try different extraction methods in order of preference
    local hostnames=()
    local extraction_method=""
    
    # Try xmllint first (most reliable)
    if command -v xmllint >/dev/null 2>&1; then
        log "Using xmllint for extraction..."
        while IFS= read -r line; do
            hostnames+=("$line")
        done < <(extract_hostnames "$manifest_file" "xmllint")
        extraction_method="xmllint"
    elif command -v python3 >/dev/null 2>&1; then
        log "Using Python for extraction..."
        while IFS= read -r line; do
            hostnames+=("$line")
        done < <(extract_hostnames "$manifest_file" "python")
        extraction_method="python"
    else
        log "Using grep/awk for extraction..."
        while IFS= read -r line; do
            hostnames+=("$line")
        done < <(extract_hostnames "$manifest_file" "grep")
        extraction_method="grep"
    fi
    
    if [ ${#hostnames[@]} -eq 0 ]; then
        error "No hostnames extracted from manifest file"
        return 1
    fi
    
    log "Extracted ${#hostnames[@]} hostnames using $extraction_method method"
    
    # Validate hostnames
    validate_hostnames "${hostnames[@]}"
    
    # Output in requested format
    case "$output_format" in
        "list")
            printf '%s\n' "${hostnames[@]}"
            ;;
        "detailed")
            echo "# CloudLab machines extracted from $manifest_file"
            echo "# Generated on $(date)"
            echo "# Extraction method: $extraction_method"
            echo ""
            
            local i=0
            for hostname in "${hostnames[@]}"; do
                echo "# Node $i"
                echo "$hostname"
                ((i++))
            done
            ;;
        "json")
            echo "{"
            echo "  \"manifest_file\": \"$manifest_file\","
            echo "  \"extraction_date\": \"$(date -Iseconds)\","
            echo "  \"extraction_method\": \"$extraction_method\","
            echo "  \"machine_count\": ${#hostnames[@]},"
            echo "  \"machines\": ["
            
            local i=0
            for hostname in "${hostnames[@]}"; do
                echo -n "    \"$hostname\""
                if [ $i -lt $((${#hostnames[@]} - 1)) ]; then
                    echo ","
                else
                    echo ""
                fi
                ((i++))
            done
            
            echo "  ]"
            echo "}"
            ;;
        *)
            printf '%s\n' "${hostnames[@]}"
            ;;
    esac
    
    return 0
}

# Function to show detailed machine information
show_machine_details() {
    local manifest_file="$1"
    
    log "Analyzing CloudLab experiment details..."
    
    echo ""
    echo "=== CloudLab Experiment Analysis ==="
    
    # Extract experiment name
    if command -v xmllint >/dev/null 2>&1; then
        echo "Experiment: $(xmllint --xpath "string(//host/@name)" "$manifest_file" 2>/dev/null | cut -d'.' -f2-3)"
    fi
    
    # Count nodes
    local node_count
    if command -v xmllint >/dev/null 2>&1; then
        node_count=$(xmllint --xpath "count(//node)" "$manifest_file" 2>/dev/null)
    else
        node_count=$(grep -c '<node ' "$manifest_file")
    fi
    echo "Total nodes: $node_count"
    
    # Extract hardware types
    echo ""
    echo "Hardware types:"
    if command -v xmllint >/dev/null 2>&1; then
        xmllint --xpath "//hardware_type/@name" "$manifest_file" 2>/dev/null | \
            sed 's/name="//g' | sed 's/"//g' | tr ' ' '\n' | sort | uniq -c | \
            while read count type; do
                echo "  $type: $count nodes"
            done
    else
        grep '<hardware_type name=' "$manifest_file" | \
            sed 's/.*name="//g' | sed 's/".*//g' | sort | uniq -c | \
            while read count type; do
                echo "  $type: $count nodes"
            done
    fi
    
    echo ""
    echo "=== Machine List ==="
    extract_machine_info "$manifest_file" "detailed"
}

# Main function
main() {
    local manifest_file="manifest.xml"
    local output_file=""
    local output_format="list"
    local show_details=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -o|--output)
                output_file="$2"
                shift 2
                ;;
            -f|--format)
                output_format="$2"
                shift 2
                ;;
            -d|--details)
                show_details=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS] [MANIFEST_FILE]"
                echo ""
                echo "Extract CloudLab machine hostnames from manifest.xml"
                echo ""
                echo "OPTIONS:"
                echo "  -o, --output FILE     Output to file instead of stdout"
                echo "  -f, --format FORMAT   Output format: list, detailed, json (default: list)"
                echo "  -d, --details         Show detailed experiment information"
                echo "  -h, --help           Show this help message"
                echo ""
                echo "FORMATS:"
                echo "  list      - Simple list of hostnames (default)"
                echo "  detailed  - Commented list with metadata"
                echo "  json      - JSON format with metadata"
                echo ""
                echo "Examples:"
                echo "  $0                           # Extract to stdout"
                echo "  $0 -o machines.txt           # Extract to file"
                echo "  $0 -f detailed -o machines.txt"
                echo "  $0 -d                        # Show detailed analysis"
                echo "  $0 my-manifest.xml           # Use different manifest file"
                exit 0
                ;;
            *)
                if [ -f "$1" ]; then
                    manifest_file="$1"
                else
                    error "File '$1' not found"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Check if manifest file exists
    if [ ! -f "$manifest_file" ]; then
        error "Manifest file '$manifest_file' not found"
        echo "Use -h for help"
        exit 1
    fi
    
    echo -e "${BLUE}"
    echo "====================================="
    echo "  CloudLab Manifest Parser"
    echo "====================================="
    echo -e "${NC}"
    
    log "Configuration:"
    log "  Manifest file: $manifest_file"
    log "  Output format: $output_format"
    log "  Output file: ${output_file:-stdout}"
    log "  Show details: $show_details"
    
    if [ "$show_details" = true ]; then
        show_machine_details "$manifest_file"
    else
        if [ -n "$output_file" ]; then
            extract_machine_info "$manifest_file" "$output_format" > "$output_file"
            success "Hostnames extracted to $output_file"
            
            # Show preview
            log "Preview of extracted hostnames:"
            head -10 "$output_file" | sed 's/^/  /'
            if [ $(wc -l < "$output_file") -gt 10 ]; then
                echo "  ... ($(wc -l < "$output_file") total lines)"
            fi
        else
            extract_machine_info "$manifest_file" "$output_format"
        fi
    fi
    
    success "Extraction completed!"
}

# Run main function with all arguments
main "$@"
