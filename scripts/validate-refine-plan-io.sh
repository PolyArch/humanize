#!/bin/bash
# validate-refine-plan-io.sh
# Validates input and output paths for the refine-plan command
# Exit codes:
#   0 - Success, all validations passed
#   1 - Input file does not exist
#   2 - Input file is empty
#   3 - Input file has no CMT:/ENDCMT blocks
#   4 - Input file missing required gen-plan sections
#   5 - Output directory does not exist (when --output differs from --input)
#   6 - QA directory not writable
#   7 - Invalid arguments

set -e

usage() {
    echo "Usage: $0 --input <path/to/annotated-plan.md> [--output <path/to/refined-plan.md>] [--qa-dir <path/to/qa-dir>] [--discussion|--direct]"
    echo ""
    echo "Options:"
    echo "  --input   Path to the input annotated plan file (required)"
    echo "  --output  Path to the output refined plan file (optional, defaults to --input for in-place mode)"
    echo "  --qa-dir  Directory for QA document output (optional, defaults to .humanize/plan_qa)"
    echo "  --discussion  Use discussion mode (interactive user confirmation for ambiguous classifications)"
    echo "  --direct      Use direct mode (skip user confirmation, use heuristic classifications)"
    echo "  -h, --help  Show this help message"
    exit 7
}

INPUT_FILE=""
OUTPUT_FILE=""
QA_DIR=".humanize/plan_qa"
REFINE_PLAN_MODE_DISCUSSION="false"
REFINE_PLAN_MODE_DIRECT="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --input)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --input requires a value"
                usage
            fi
            INPUT_FILE="$2"
            shift 2
            ;;
        --output)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --output requires a value"
                usage
            fi
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --qa-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --qa-dir requires a value"
                usage
            fi
            QA_DIR="$2"
            shift 2
            ;;
        --discussion)
            REFINE_PLAN_MODE_DISCUSSION="true"
            shift
            ;;
        --direct)
            REFINE_PLAN_MODE_DIRECT="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            ;;
    esac
done

# Validate mutually exclusive flags
if [[ "$REFINE_PLAN_MODE_DISCUSSION" == "true" && "$REFINE_PLAN_MODE_DIRECT" == "true" ]]; then
    echo "Error: --discussion and --direct are mutually exclusive"
    exit 7
fi

# Validate required arguments
if [[ -z "$INPUT_FILE" ]]; then
    echo "ERROR: --input is required"
    usage
fi

# Default output to input (in-place mode)
if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$INPUT_FILE"
fi

# Get absolute paths
INPUT_FILE=$(realpath -m "$INPUT_FILE" 2>/dev/null || echo "$INPUT_FILE")
OUTPUT_FILE=$(realpath -m "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")

echo "=== refine-plan IO Validation ==="
echo "Input file: $INPUT_FILE"
echo "Output file: $OUTPUT_FILE"
echo "Output directory: $OUTPUT_DIR"
echo "QA directory: $QA_DIR"

# Check 1: Input file exists
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "VALIDATION_ERROR: INPUT_NOT_FOUND"
    echo "The input file does not exist: $INPUT_FILE"
    echo "Please ensure the annotated plan file exists before running refine-plan."
    exit 1
fi

# Check 2: Input file is not empty
if [[ ! -s "$INPUT_FILE" ]]; then
    echo "VALIDATION_ERROR: INPUT_EMPTY"
    echo "The input file is empty: $INPUT_FILE"
    echo "Please add content to your annotated plan file before running refine-plan."
    exit 2
fi

# Check 3: Input file has at least one CMT:/ENDCMT block
if ! grep -q 'CMT:' "$INPUT_FILE"; then
    echo "VALIDATION_ERROR: NO_CMT_BLOCKS"
    echo "The input file has no CMT: blocks: $INPUT_FILE"
    echo "refine-plan requires at least one CMT:/ENDCMT comment block in the input."
    exit 3
fi

# Check 4: Input file has required gen-plan sections
REQUIRED_SECTIONS=(
    "## Goal Description"
    "## Acceptance Criteria"
    "## Path Boundaries"
    "## Feasibility Hints"
    "## Dependencies and Sequence"
    "## Task Breakdown"
    "## Claude-Codex Deliberation"
    "## Pending User Decisions"
    "## Implementation Notes"
)

MISSING_SECTIONS=()
for section in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -qF "$section" "$INPUT_FILE"; then
        MISSING_SECTIONS+=("$section")
    fi
done

if [[ ${#MISSING_SECTIONS[@]} -gt 0 ]]; then
    echo "VALIDATION_ERROR: MISSING_REQUIRED_SECTIONS"
    echo "The input file is missing required gen-plan sections:"
    for section in "${MISSING_SECTIONS[@]}"; do
        echo "  - $section"
    done
    echo "Please ensure the input file follows the gen-plan schema."
    exit 4
fi

# Check 5: Output directory exists (only when output differs from input)
if [[ "$OUTPUT_FILE" != "$INPUT_FILE" ]]; then
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        echo "VALIDATION_ERROR: OUTPUT_DIR_NOT_FOUND"
        echo "The output directory does not exist: $OUTPUT_DIR"
        echo "Please create the directory: mkdir -p $OUTPUT_DIR"
        exit 5
    fi
fi

# Check 6: QA directory is writable (auto-create if it doesn't exist)
if [[ ! -d "$QA_DIR" ]]; then
    echo "NOTE: QA directory does not exist, will auto-create: $QA_DIR"
    mkdir -p "$QA_DIR" || {
        echo "VALIDATION_ERROR: QA_DIR_NOT_WRITABLE"
        echo "Failed to create QA directory: $QA_DIR"
        echo "Please check permissions."
        exit 6
    }
fi

if [[ ! -w "$QA_DIR" ]]; then
    echo "VALIDATION_ERROR: QA_DIR_NOT_WRITABLE"
    echo "No write permission for the QA directory: $QA_DIR"
    echo "Please check directory permissions."
    exit 6
fi

# All checks passed
INPUT_LINE_COUNT=$(wc -l < "$INPUT_FILE" | tr -d ' ')
CMT_BLOCK_COUNT=$(grep -c 'CMT:' "$INPUT_FILE" || echo "0")
echo "VALIDATION_SUCCESS"
echo "Input file: $INPUT_FILE ($INPUT_LINE_COUNT lines, $CMT_BLOCK_COUNT CMT blocks)"
echo "Output target: $OUTPUT_FILE"
if [[ "$OUTPUT_FILE" == "$INPUT_FILE" ]]; then
    echo "Mode: in-place (atomic write with temp file)"
else
    echo "Mode: new file"
fi
echo "QA directory: $QA_DIR"
echo "IO validation passed."
exit 0
