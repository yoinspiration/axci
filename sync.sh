#!/bin/bash
# Sync Script - Synchronize changes between monorepo and component repos using git subtree
#
# This script uses git subtree for bidirectional sync, preserving full commit history.
#
# Usage:
#   ./sync.sh --push [--component <name>] [--branch <branch>] [--dry-run]
#   ./sync.sh --pull --component <name> [--branch <branch>] [--dry-run]
#
# Options:
#   --push             Push changes from monorepo to component repos (git subtree push)
#   --pull             Pull changes from component repo to monorepo (git subtree pull)
#   --component <name> Component name to sync (optional for --push, required for --pull)
#   --branch <branch>  Branch name (default: main or master)
#   --dry-run          Only show what would be synced
#   --help             Show this help message

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
SYNC_DIRECTION=""
COMPONENT=""
BRANCH=""
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --push)
            SYNC_DIRECTION="push"
            shift
            ;;
        --pull)
            SYNC_DIRECTION="pull"
            shift
            ;;
        --component)
            COMPONENT="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            sed -n '2,17p' "$0" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Validate arguments
if [ -z "$SYNC_DIRECTION" ]; then
    echo -e "${RED}Error: Must specify --push or --pull${NC}"
    exit 1
fi

if [ "$SYNC_DIRECTION" = "pull" ] && [ -z "$COMPONENT" ]; then
    echo -e "${RED}Error: --component is required for --pull${NC}"
    exit 1
fi

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get component repository URL from Cargo.toml
get_component_repo() {
    local component=$1
    local cargo_toml="$component/Cargo.toml"
    
    if [ ! -f "$cargo_toml" ]; then
        return 1
    fi
    
    grep -P 'repository\s*=' "$cargo_toml" | \
        sed 's/.*repository\s*=\s*"\(.*\)".*/\1/' | \
        head -1
}

# Detect default branch from remote
detect_branch() {
    local repo_url=$1
    
    # Try common branch names
    if git ls-remote --heads "$repo_url" 2>/dev/null | grep -q 'refs/heads/main$'; then
        echo "main"
    elif git ls-remote --heads "$repo_url" 2>/dev/null | grep -q 'refs/heads/master$'; then
        echo "master"
    elif git ls-remote --heads "$repo_url" 2>/dev/null | grep -q 'refs/heads/dev$'; then
        echo "dev"
    else
        echo "main"  # Default fallback
    fi
}

# Detect changed components
detect_changed_components() {
    local components=()
    
    # Get list of changed files in the last commit
    if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        local changed_files
        changed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || git ls-files)
        
        # Find unique component directories
        local seen_components=""
        for file in $changed_files; do
            local component=$(echo "$file" | cut -d'/' -f1)
            
            # Skip if already seen or not a valid component
            if [[ "$seen_components" == *"$component"* ]]; then
                continue
            fi
            
            if [ -f "$component/Cargo.toml" ] && \
               [ "$component" != ".github" ] && \
               [ "$component" != "scripts" ] && \
               [ "$component" != "axci" ]; then
                # Check if repository URL exists
                if grep -q 'repository\s*=' "$component/Cargo.toml"; then
                    components+=("$component")
                    seen_components="$seen_components $component"
                fi
            fi
        done
    fi
    
    echo "${components[@]}"
}

# Push from monorepo to component repo using git subtree
push_to_component() {
    local component=$1
    local repo_url=$(get_component_repo "$component")
    
    if [ -z "$repo_url" ]; then
        log_warning "No repository URL found in $component/Cargo.toml, skipping"
        return 0
    fi
    
    # Detect branch if not specified
    local target_branch=${BRANCH:-$(detect_branch "$repo_url")}
    
    log_info "Pushing $component to $repo_url (branch: $target_branch)"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would execute: git subtree push --prefix=$component $repo_url $target_branch"
        return 0
    fi
    
    # Use git subtree push to push changes back to component repo
    # This preserves all commit history
    git subtree push --prefix="$component" "$repo_url" "$target_branch"
    
    log_success "Successfully pushed $component to $repo_url"
}

# Pull from component repo to monorepo using git subtree
pull_from_component() {
    local component=$1
    local repo_url=$(get_component_repo "$component")
    
    if [ -z "$repo_url" ]; then
        log_error "No repository URL found in $component/Cargo.toml"
        return 1
    fi
    
    # Detect branch if not specified
    local target_branch=${BRANCH:-$(detect_branch "$repo_url")}
    
    log_info "Pulling updates from $repo_url (branch: $target_branch) to $component"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would execute: git subtree pull --prefix=$component $repo_url $target_branch"
        return 0
    fi
    
    # Use git subtree pull to get updates from component repo
    # This preserves all commit history and handles merges
    git subtree pull --prefix="$component" "$repo_url" "$target_branch" \
        --message "sync: Update $component from upstream"
    
    log_success "Successfully pulled updates to $component"
}

# Main execution
main() {
    log_info "Starting sync (direction: $SYNC_DIRECTION)"
    
    # Check if we're in a git repository
    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        log_error "Not in a git repository"
        exit 1
    fi
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        if [ -n "$COMPONENT" ]; then
            # Push specific component
            push_to_component "$COMPONENT"
        else
            # Detect and push all changed components
            local components=$(detect_changed_components)
            
            if [ -z "$components" ]; then
                log_info "No changed components detected"
                exit 0
            fi
            
            log_info "Detected changed components: $components"
            
            for component in $components; do
                push_to_component "$component"
            done
        fi
    elif [ "$SYNC_DIRECTION" = "pull" ]; then
        pull_from_component "$COMPONENT"
    fi
    
    log_success "Sync completed"
}

main
