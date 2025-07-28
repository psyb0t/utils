#!/bin/bash
#
# publish-to-archidedotorg.sh
# CLI helper to push any file to archive.org via the ia CLI tool.
#

set -euo pipefail

show_help() {
    cat << EOF
Usage: $0 <file> [OPTIONS]

Upload a file to archive.org with full metadata.

ARGUMENTS:
    file                    Path to the file to upload

OPTIONS:
    --identifier <id>       Unique IA item identifier
    --title <title>         Item title (defaults to filename)
    --description <desc>    Item description (defaults to upload details)
    --zim                   ZIM file mode: sets mediatype=data, auto-detects creator/date from filename
    --pdf                   PDF file mode: sets mediatype=texts, extracts metadata from PDF

    MEDIA TYPE FLAGS (choose one, required unless using --zim or --pdf):
    --mediatype-texts       Text items (PDFs, EPUBs, books, documents)
    --mediatype-audio       Audio files (music, podcasts, recordings)
    --mediatype-movies      Videos (films, TV shows, documentaries)
    --mediatype-software    Software, applications, games
    --mediatype-web         Web archives (WARC files)
    --mediatype-image       Image collections and photos
    --mediatype-data        Data files, datasets
    --mediatype-etree       Live concert recordings (etree format)
    --mediatype-collection  Collection container for other items

    --subjects <keywords>   Comma-separated subject keywords
    --creator <name>        Creator / author field
    --date <date>           Date string (YYYY-MM-DD or free-text)
    --license <license>     License info
    --help                  Show this help message

NOTES:
    The script automatically populates many fields to simplify uploads:

    • Title: Defaults to filename with extension if not specified
    • Description: Auto-generated from upload details (filename, size, mediatype,
      and any other specified metadata) if not provided
    • Identifier: Auto-generated from filename + timestamp if not specified
    • ZIM mode (--zim): Auto-detects creator and date from filename pattern "domain_YYYY-MM.zim"
    • PDF mode (--pdf): Extracts title, author, creation date, subject from PDF metadata
    • Auto-detection: .zim files automatically use --zim mode, .pdf files use --pdf mode

    If no mediatype is specified, the script will try to auto-detect based on file extension.
    For other file types, you must specify a mediatype flag.

EXAMPLES:
    # Auto-detected PDF upload - no flags needed!
    $0 research-paper.pdf
    # Auto-detects PDF mode and generates everything automatically

    # Auto-detected ZIM upload - no flags needed!
    $0 wiki.gnuradio.org_2025-07.zim
    # Auto-detects ZIM mode, extracts creator/date from filename

    # Manual mediatype for other files
    $0 dataset.zip --mediatype-data
    # Auto-generates:
    #   Title: dataset.zip
    #   Description: - Filename: dataset.zip
    #                - File size: 45M
    #                - Mediatype: data
    #   Identifier: dataset-zip-20250728142030

    # PDF upload with metadata extraction
    $0 research-paper.pdf --pdf
    # Auto-extracts from PDF metadata (if available):
    #   Title: "Climate Change Impact on Arctic Wildlife" (from PDF title)
    #   Creator: "Dr. Jane Smith" (from PDF author)
    #   Date: "2024-03-15" (from PDF creation date)
    #   Subjects: "climate change, wildlife, arctic" (from PDF subject)
    #   Mediatype: texts

    # Upload with some custom metadata
    $0 dataset.zip --mediatype-data --creator "John Doe" --subjects "climate,research"
    # Auto-generates title, description (including creator & subjects), identifier

    # Full manual control (override all defaults)
    $0 my-file.zip \\
      --identifier "custom-archive-2024" \\
      --title "My Custom Archive" \\
      --description "A manually described archive of important files" \\
      --mediatype-data \\
      --creator "Jane Smith" \\
      --license "WTFPL"

SETUP:
    First-time setup (run once):
    ia configure

EOF
}

# Helper functions
slugify() {
    local text="$1"
    # Convert to lowercase, replace non-alphanumeric with hyphens, collapse multiple hyphens
    echo "$text" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/-\+/-/g' | sed 's/^-\|-$//g'
}

build_identifier() {
    local filepath="$1"
    local basename=$(basename "$filepath")
    local stem="${basename%.*}"
    local slug=$(slugify "$stem")
    local timestamp=$(date -u +%Y%m%d%H%M%S)
    echo "${slug}-${timestamp}"
}

parse_zim_filename() {
    local filename="$1"
    local basename=$(basename "$filename" .zim)

    # Extract website URL and date from pattern: website.domain_YYYY-MM
    if [[ "$basename" =~ ^(.+)_([0-9]{4}-[0-9]{2})$ ]]; then
        local website="${BASH_REMATCH[1]}"
        local date_part="${BASH_REMATCH[2]}"

        # Use website domain as creator (no schema prefix)
        local creator_url="$website"

        # Add day to make complete date (1st of the month)
        local full_date="${date_part}-01"

        echo "creator:$creator_url"
        echo "date:$full_date"
        return 0
    fi

    return 1
}

auto_detect_file_type() {
    local filename="$1"
    local extension="${filename##*.}"
    extension=$(echo "$extension" | tr '[:upper:]' '[:lower:]')

    case "$extension" in
        zim)
            echo "zim"
            ;;
        pdf)
            echo "pdf"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}


parse_pdf_metadata() {
    local filename="$1"

    # Check if pdfinfo is available
    if ! command -v pdfinfo &> /dev/null; then
        return 1
    fi

    # Extract PDF metadata using pdfinfo
    local pdf_info
    if ! pdf_info=$(pdfinfo "$filename" 2>/dev/null); then
        return 1
    fi

    # Parse fields from pdfinfo output
    local pdf_title pdf_author pdf_subject pdf_creation_date

    pdf_title=$(echo "$pdf_info" | grep "^Title:" | sed 's/^Title:[[:space:]]*//' | head -1)
    pdf_author=$(echo "$pdf_info" | grep "^Author:" | sed 's/^Author:[[:space:]]*//' | head -1)
    pdf_subject=$(echo "$pdf_info" | grep "^Subject:" | sed 's/^Subject:[[:space:]]*//' | head -1)
    pdf_creation_date=$(echo "$pdf_info" | grep "^CreationDate:" | sed 's/^CreationDate:[[:space:]]*//' | head -1)

    # Convert PDF date format (e.g., "D:20240727142030+00'00'") to YYYY-MM-DD
    if [[ "$pdf_creation_date" =~ D:([0-9]{4})([0-9]{2})([0-9]{2}) ]]; then
        pdf_creation_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    fi

    # Output found metadata
    [[ -n "$pdf_title" ]] && echo "title:$pdf_title"
    [[ -n "$pdf_author" ]] && echo "creator:$pdf_author"
    [[ -n "$pdf_subject" ]] && echo "subjects:$pdf_subject"
    [[ -n "$pdf_creation_date" ]] && echo "date:$pdf_creation_date"

    return 0
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

pretty_exit() {
    local msg="$1"
    local code="${2:-1}"
    echo -e "❌ ${RED}Error:${NC} $msg" >&2
    exit "$code"
}

get_mediatype_selection() {
    local count=0
    local selected_type=""

    [[ "$MEDIATYPE_TEXTS" == "true" ]] && ((count++)) && selected_type="texts"
    [[ "$MEDIATYPE_AUDIO" == "true" ]] && ((count++)) && selected_type="audio"
    [[ "$MEDIATYPE_MOVIES" == "true" ]] && ((count++)) && selected_type="movies"
    [[ "$MEDIATYPE_SOFTWARE" == "true" ]] && ((count++)) && selected_type="software"
    [[ "$MEDIATYPE_WEB" == "true" ]] && ((count++)) && selected_type="web"
    [[ "$MEDIATYPE_IMAGE" == "true" ]] && ((count++)) && selected_type="image"
    [[ "$MEDIATYPE_DATA" == "true" ]] && ((count++)) && selected_type="data"
    [[ "$MEDIATYPE_ETREE" == "true" ]] && ((count++)) && selected_type="etree"
    [[ "$MEDIATYPE_COLLECTION" == "true" ]] && ((count++)) && selected_type="collection"

    # If ZIM mode, override mediatype to data
    if [[ "$ZIM_MODE" == "true" ]]; then
        selected_type="data"
    # If PDF mode, override mediatype to texts
    elif [[ "$PDF_MODE" == "true" ]]; then
        selected_type="texts"
    elif [[ $count -gt 1 ]]; then
        return 1  # Multiple mediatypes
    elif [[ $count -eq 0 ]]; then
        # Try auto-detection based on file extension
        if auto_detected_type=$(auto_detect_file_type "$FILE"); then
            if [[ "$auto_detected_type" == "zim" ]]; then
                ZIM_MODE="true"
                selected_type="data"
            elif [[ "$auto_detected_type" == "pdf" ]]; then
                PDF_MODE="true"
                selected_type="texts"
            fi
        else
            return 2  # No mediatype specified and can't auto-detect
        fi
    fi

    echo "$selected_type"
    return 0
}

validate_and_set_mediatype() {
    local count=0

    [[ "$MEDIATYPE_TEXTS" == "true" ]] && ((count++))
    [[ "$MEDIATYPE_AUDIO" == "true" ]] && ((count++))
    [[ "$MEDIATYPE_MOVIES" == "true" ]] && ((count++))
    [[ "$MEDIATYPE_SOFTWARE" == "true" ]] && ((count++))
    [[ "$MEDIATYPE_WEB" == "true" ]] && ((count++))
    [[ "$MEDIATYPE_IMAGE" == "true" ]] && ((count++))
    [[ "$MEDIATYPE_DATA" == "true" ]] && ((count++))
    [[ "$MEDIATYPE_ETREE" == "true" ]] && ((count++))
    [[ "$MEDIATYPE_COLLECTION" == "true" ]] && ((count++))

    # Check for conflicts and warnings
    if [[ "$ZIM_MODE" == "true" && $count -gt 0 ]]; then
        echo -e "⚠️  ${YELLOW}Warning: --zim mode overrides mediatype to 'data'${NC}"
    elif [[ "$PDF_MODE" == "true" && $count -gt 0 ]]; then
        echo -e "⚠️  ${YELLOW}Warning: --pdf mode overrides mediatype to 'texts'${NC}"
    elif [[ $count -gt 1 ]]; then
        pretty_exit "Only one mediatype flag can be specified"
    elif [[ $count -eq 0 && "$ZIM_MODE" == "false" && "$PDF_MODE" == "false" ]]; then
        # Try auto-detection
        if auto_detected_type=$(auto_detect_file_type "$FILE"); then
            echo -e "🎯 ${YELLOW}Auto-detected file type:${NC} $auto_detected_type mode"
            # Set the global mode variables
            if [[ "$auto_detected_type" == "zim" ]]; then
                ZIM_MODE="true"
            elif [[ "$auto_detected_type" == "pdf" ]]; then
                PDF_MODE="true"
            fi
        else
            pretty_exit "A mediatype flag is required. Use one of: --mediatype-texts, --mediatype-audio, --mediatype-movies, --mediatype-software, --mediatype-web, --mediatype-image, --mediatype-data, --mediatype-etree, --mediatype-collection, --zim, or --pdf"
        fi
    fi

    # Get the actual mediatype
    MEDIATYPE=$(get_mediatype_selection)
}

# Default values
TITLE=""
DESCRIPTION=""
IDENTIFIER=""
SUBJECTS=""
CREATOR=""
DATE=""
LICENSE=""
ZIM_MODE="false"
PDF_MODE="false"
ZIM_AUTO_DETECTED="false"
PDF_AUTO_DETECTED="false"

# Media type flags (only one should be true)
MEDIATYPE_TEXTS="false"
MEDIATYPE_AUDIO="false"
MEDIATYPE_MOVIES="false"
MEDIATYPE_SOFTWARE="false"
MEDIATYPE_WEB="false"
MEDIATYPE_IMAGE="false"
MEDIATYPE_DATA="false"
MEDIATYPE_ETREE="false"
MEDIATYPE_COLLECTION="false"

# Parse command line arguments
FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            exit 0
            ;;
        --identifier)
            IDENTIFIER="$2"
            shift 2
            ;;
        --title)
            TITLE="$2"
            shift 2
            ;;
        --description)
            DESCRIPTION="$2"
            shift 2
            ;;
        --zim)
            ZIM_MODE="true"
            shift
            ;;
        --pdf)
            PDF_MODE="true"
            shift
            ;;
        --mediatype-texts)
            MEDIATYPE_TEXTS="true"
            shift
            ;;
        --mediatype-audio)
            MEDIATYPE_AUDIO="true"
            shift
            ;;
        --mediatype-movies)
            MEDIATYPE_MOVIES="true"
            shift
            ;;
        --mediatype-software)
            MEDIATYPE_SOFTWARE="true"
            shift
            ;;
        --mediatype-web)
            MEDIATYPE_WEB="true"
            shift
            ;;
        --mediatype-image)
            MEDIATYPE_IMAGE="true"
            shift
            ;;
        --mediatype-data)
            MEDIATYPE_DATA="true"
            shift
            ;;
        --mediatype-etree)
            MEDIATYPE_ETREE="true"
            shift
            ;;
        --mediatype-collection)
            MEDIATYPE_COLLECTION="true"
            shift
            ;;
        --subjects)
            SUBJECTS="$2"
            shift 2
            ;;
        --creator)
            CREATOR="$2"
            shift 2
            ;;
        --date)
            DATE="$2"
            shift 2
            ;;
        --license)
            LICENSE="$2"
            shift 2
            ;;
        -*)
            pretty_exit "Unknown option: $1"
            ;;
        *)
            if [[ -z "$FILE" ]]; then
                FILE="$1"
            else
                pretty_exit "Multiple files specified. Only one file is allowed."
            fi
            shift
            ;;
    esac
done

# Sanity checks
if [[ -z "$FILE" ]]; then
    echo -e "❌ ${RED}Error: No file specified.${NC}" >&2
    echo "" >&2
    show_help
    exit 1
fi

if [[ ! -f "$FILE" ]]; then
    pretty_exit "File not found: $FILE"
fi

# Auto-set title from filename if not provided
if [[ -z "$TITLE" ]]; then
    TITLE=$(basename "$FILE")  # Keep extension
    echo -e "📝 ${CYAN}Auto-set title from filename:${NC} $TITLE"
fi



# Handle PDF mode metadata auto-population
if [[ "$PDF_MODE" == "true" ]]; then

    # Try to extract metadata from PDF
    if parse_result=$(parse_pdf_metadata "$FILE"); then
        # Track what was auto-detected for confirmation prompt
        auto_detected_fields=()

        # Extract metadata from parse result
        while IFS= read -r line; do
            if [[ "$line" =~ ^title:(.+)$ ]]; then
                pdf_title="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^creator:(.+)$ ]]; then
                pdf_creator="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^subjects:(.+)$ ]]; then
                pdf_subjects="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^date:(.+)$ ]]; then
                pdf_date="${BASH_REMATCH[1]}"
            fi
        done <<< "$parse_result"

        # Set fields if not already specified by user
        if [[ -z "$TITLE" && -n "$pdf_title" ]]; then
            TITLE="$pdf_title"
            auto_detected_fields+=("title: $TITLE")
        fi

        if [[ -z "$CREATOR" && -n "$pdf_creator" ]]; then
            CREATOR="$pdf_creator"
            auto_detected_fields+=("creator: $CREATOR")
        fi

        if [[ -z "$SUBJECTS" && -n "$pdf_subjects" ]]; then
            SUBJECTS="$pdf_subjects"
            auto_detected_fields+=("subjects: $SUBJECTS")
        fi

        if [[ -z "$DATE" && -n "$pdf_date" ]]; then
            DATE="$pdf_date"
            auto_detected_fields+=("date: $DATE")
        fi

        # Show confirmation if any fields were auto-detected
        if [[ ${#auto_detected_fields[@]} -gt 0 ]]; then
            echo -e "📄 ${BLUE}Auto-detected from PDF metadata:${NC}"
            for field in "${auto_detected_fields[@]}"; do
                echo -e "  ✨ $field"
            done
            echo ""
            PDF_AUTO_DETECTED="true"
        fi
    fi
fi

# Validate and get the selected mediatype
validate_and_set_mediatype

# Handle ZIM mode metadata auto-population (moved here after mediatype validation)
if [[ "$ZIM_MODE" == "true" ]]; then

    # Try to parse creator and date from ZIM filename
    if parse_result=$(parse_zim_filename "$FILE"); then
        # Extract creator and date from parse result
        while IFS= read -r line; do
            if [[ "$line" =~ ^creator:(.+)$ ]]; then
                zim_creator="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^date:(.+)$ ]]; then
                zim_date="${BASH_REMATCH[1]}"
            fi
        done <<< "$parse_result"

        # Track what was auto-detected for confirmation prompt
        auto_detected_fields=()

        # Set creator and date if not already specified by user
        if [[ -z "$CREATOR" && -n "$zim_creator" ]]; then
            CREATOR="$zim_creator"
            auto_detected_fields+=("creator: $CREATOR")
        fi

        if [[ -z "$DATE" && -n "$zim_date" ]]; then
            DATE="$zim_date"
            auto_detected_fields+=("date: $DATE")
        fi

        # Show confirmation if any fields were auto-detected
        if [[ ${#auto_detected_fields[@]} -gt 0 ]]; then
            echo -e "🔍 ${PURPLE}Auto-detected from ZIM filename:${NC}"
            for field in "${auto_detected_fields[@]}"; do
                echo -e "  ✨ $field"
            done
            echo ""
            ZIM_AUTO_DETECTED="true"
        fi
    fi
fi

# Auto-generate description if not provided
if [[ -z "$DESCRIPTION" ]]; then
    FILE_SIZE=$(du -h "$FILE" | cut -f1)
    DESCRIPTION="- Filename: $(basename "$FILE")
- File size: $FILE_SIZE
- Mediatype: $MEDIATYPE"

    # Add optional fields if they exist
    if [[ -n "$CREATOR" ]]; then
        DESCRIPTION="$DESCRIPTION
- Creator: $CREATOR"
    fi

    if [[ -n "$DATE" ]]; then
        DESCRIPTION="$DESCRIPTION
- Date: $DATE"
    fi

    if [[ -n "$LICENSE" ]]; then
        DESCRIPTION="$DESCRIPTION
- License: $LICENSE"
    fi

    if [[ -n "$SUBJECTS" ]]; then
        DESCRIPTION="$DESCRIPTION
- Subjects: $SUBJECTS"
    fi

    if [[ -n "$IDENTIFIER" ]]; then
        DESCRIPTION="$DESCRIPTION
- Identifier: $IDENTIFIER"
    fi

    echo -e "📋 ${GREEN}Auto-generated description from upload details${NC}"
fi

# Build identifier if not provided
if [[ -z "$IDENTIFIER" ]]; then
    IDENTIFIER=$(build_identifier "$FILE")
fi


# Build metadata arguments
METADATA_ARGS=()
METADATA_ARGS+=("--metadata" "title:$TITLE")
METADATA_ARGS+=("--metadata" "description:$DESCRIPTION")
METADATA_ARGS+=("--metadata" "mediatype:$MEDIATYPE")

if [[ -n "$SUBJECTS" ]]; then
    METADATA_ARGS+=("--metadata" "subject:$SUBJECTS")
fi

if [[ -n "$CREATOR" ]]; then
    METADATA_ARGS+=("--metadata" "creator:$CREATOR")
fi

if [[ -n "$DATE" ]]; then
    METADATA_ARGS+=("--metadata" "date:$DATE")
fi

if [[ -n "$LICENSE" ]]; then
    METADATA_ARGS+=("--metadata" "license:$LICENSE")
fi

echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           📤 UPLOAD DETAILS           ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
echo -e "📁 ${BOLD}File:${NC} $FILE"
echo -e "🆔 ${BOLD}Identifier:${NC} $IDENTIFIER"
echo -e "📝 ${BOLD}Title:${NC} $TITLE"
echo -e "📄 ${BOLD}Description:${NC}"
echo "$DESCRIPTION" | sed 's/^/    /'
echo -e "🎭 ${BOLD}Media Type:${NC} $MEDIATYPE"
if [[ -n "$SUBJECTS" ]]; then echo -e "🏷️  ${BOLD}Subjects:${NC} $SUBJECTS"; fi
if [[ -n "$CREATOR" ]]; then echo -e "👤 ${BOLD}Creator:${NC} $CREATOR"; fi
if [[ -n "$DATE" ]]; then echo -e "📅 ${BOLD}Date:${NC} $DATE"; fi
if [[ -n "$LICENSE" ]]; then echo -e "⚖️  ${BOLD}License:${NC} $LICENSE"; fi
echo -e "${CYAN}═══════════════════════════════════════${NC}"


# Check if ia command is available
if ! command -v ia &> /dev/null; then
    pretty_exit "ia command not found. Please install internetarchive: pip install internetarchive"
fi

# Check if ia is configured by testing with a known item
if ! ia metadata internetarchive >/dev/null 2>&1; then
    pretty_exit "ia not configured. Run 'ia configure' to set up your Internet Archive account."
fi

# Upload
echo -e "🚀 ${YELLOW}Starting upload...${NC}"
echo ""
if ia upload "$IDENTIFIER" "$FILE" "${METADATA_ARGS[@]}" --retries 3 --verify; then
    echo ""
    echo -e "🎉 ${GREEN}${BOLD}Upload complete!${NC} 🌟"
    echo -e "📄 ${BLUE}Item page: https://archive.org/details/$IDENTIFIER${NC}"
    echo -e "⬇️  ${CYAN}Direct download: https://archive.org/download/$IDENTIFIER/$(basename "$FILE")${NC}"
else
    pretty_exit "Upload failed"
fi
