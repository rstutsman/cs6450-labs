#!/bin/bash

# Script to install the latest version of Go on CloudLab machines
# Usage: ./install-go-cloudlab.sh machines.txt
# Where machines.txt contains one hostname per line

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default Go version (will be updated to latest)
GO_VERSION="1.24.5"
GO_ARCH="linux-amd64"

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

# Function to get the latest Go version
get_latest_go_version() {
    log "Fetching latest Go version..."
    
    # Try to get latest version from Go's release API
    if command -v curl >/dev/null 2>&1; then
        LATEST_VERSION=$(curl -s https://golang.org/VERSION?m=text 2>/dev/null | head -n1)
        if [[ $LATEST_VERSION =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            GO_VERSION=${LATEST_VERSION#go}  # Remove 'go' prefix
            success "Latest Go version: $GO_VERSION"
        else
            warning "Could not fetch latest version, using default: $GO_VERSION"
        fi
    else
        warning "curl not available, using default Go version: $GO_VERSION"
    fi
}

# Function to install Go on a single machine
install_go_on_machine() {
    local machine=$1
    local username=${2:-$(whoami)}
    
    log "Installing Go $GO_VERSION on $machine..."
    
    # Create the installation script
    local install_script=$(cat << 'EOF'
#!/bin/bash
set -e

GO_VERSION="$1"
GO_ARCH="$2"

echo "Installing Go $GO_VERSION..."

# Remove any existing Go installation
if [ -d "$HOME/go" ]; then
    echo "Removing existing Go installation..."
    rm -rf "$HOME/go"
fi

# Create temporary directory
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

# Download Go
GO_TAR="go${GO_VERSION}.${GO_ARCH}.tar.gz"
echo "Downloading $GO_TAR..."

if command -v wget >/dev/null 2>&1; then
    wget -q "https://golang.org/dl/$GO_TAR"
elif command -v curl >/dev/null 2>&1; then
    curl -sL "https://golang.org/dl/$GO_TAR" -o "$GO_TAR"
else
    echo "Error: Neither wget nor curl is available"
    exit 1
fi

# Verify download
if [ ! -f "$GO_TAR" ]; then
    echo "Error: Failed to download Go"
    exit 1
fi

# Extract Go
echo "Extracting Go..."
tar -xf "$GO_TAR"

# Move to home directory
mv go "$HOME/"

# Clean up
cd "$HOME"
rm -rf "$TMP_DIR"

# Update shell profile
SHELL_PROFILE=""
if [ -f "$HOME/.bashrc" ]; then
    SHELL_PROFILE="$HOME/.bashrc"
elif [ -f "$HOME/.bash_profile" ]; then
    SHELL_PROFILE="$HOME/.bash_profile"
elif [ -f "$HOME/.zshrc" ]; then
    SHELL_PROFILE="$HOME/.zshrc"
else
    SHELL_PROFILE="$HOME/.profile"
fi

# Remove any existing Go PATH entries
if [ -f "$SHELL_PROFILE" ]; then
    sed -i '/# Go PATH/d' "$SHELL_PROFILE" 2>/dev/null || true
    sed -i '/export PATH.*\/go\/bin/d' "$SHELL_PROFILE" 2>/dev/null || true
    sed -i '/export GOPATH/d' "$SHELL_PROFILE" 2>/dev/null || true
fi

# Add Go to PATH
echo "" >> "$SHELL_PROFILE"
echo "# Go PATH" >> "$SHELL_PROFILE"
echo "export PATH=\$HOME/go/bin:\$PATH" >> "$SHELL_PROFILE"
echo "export GOPATH=\$HOME/gopath" >> "$SHELL_PROFILE"

# Create GOPATH directory
mkdir -p "$HOME/gopath"

# Verify installation
if [ -f "$HOME/go/bin/go" ]; then
    GO_INSTALLED_VERSION=$("$HOME/go/bin/go" version)
    echo "Success: $GO_INSTALLED_VERSION installed"
    echo "Go installed in: $HOME/go"
    echo "GOPATH set to: $HOME/gopath"
    echo "Added to shell profile: $SHELL_PROFILE"
    echo "Run 'source $SHELL_PROFILE' or restart your shell to use Go"
else
    echo "Error: Go installation failed"
    exit 1
fi
EOF
)

    # Execute the installation script on the remote machine
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$username@$machine" "bash -s" -- "$GO_VERSION" "$GO_ARCH" <<< "$install_script"; then
        success "Go installed successfully on $machine"
        return 0
    else
        error "Failed to install Go on $machine"
        return 1
    fi
}

# Function to install Go on all machines in parallel
install_go_parallel() {
    local machines_file=$1
    local username=$2
    local max_parallel=${3:-5}
    
    if [ ! -f "$machines_file" ]; then
        error "Machines file '$machines_file' not found"
        exit 1
    fi
    
    log "Starting parallel installation on machines from $machines_file"
    log "Max parallel jobs: $max_parallel"
    
    # Read machines into array
    machines=()
    while IFS= read -r line; do
        machines+=("$line")
    done < "$machines_file"
    
    if [ ${#machines[@]} -eq 0 ]; then
        error "No machines found in $machines_file"
        exit 1
    fi
    
    log "Found ${#machines[@]} machines"
    
    # Install Go on all machines in parallel
    local pids=()
    local results=()
    local job_count=0
    
    for machine in "${machines[@]}"; do
        # Skip empty lines and comments
        [[ -z "$machine" || "$machine" =~ ^[[:space:]]*# ]] && continue
        
        # Wait if we've reached max parallel jobs
        while [ ${#pids[@]} -ge $max_parallel ]; do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    wait "${pids[$i]}"
                    results[$i]=$?
                    unset pids[$i]
                fi
            done
            sleep 1
        done
        
        # Start new job
        log "Starting installation on $machine (job $((job_count + 1)))"
        install_go_on_machine "$machine" "$username" &
        pids+=($!)
        ((job_count++))
    done
    
    # Wait for all remaining jobs
    log "Waiting for remaining installations to complete..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    log "All installations completed"
}

# Function to test Go installation on all machines
test_installations() {
    local machines_file=$1
    local username=$2
    
    log "Testing Go installations..."
    
    machines=()
    while IFS= read -r line; do
        machines+=("$line")
    done < "$machines_file"

    local success_count=0
    local total_count=0
    
    for machine in "${machines[@]}"; do
        [[ -z "$machine" || "$machine" =~ ^[[:space:]]*# ]] && continue
        
        ((total_count++))
        log "Testing Go on $machine..."
        
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$username@$machine" "\$HOME/go/bin/go version" 2>/dev/null; then
            success "Go is working on $machine"
            ((success_count++))
        else
            error "Go test failed on $machine"
        fi
    done
    
    log "Installation test complete: $success_count/$total_count machines successful"
}

# Main function
main() {
    echo -e "${BLUE}"
    echo "======================================"
    echo "  CloudLab Go Installation Script"
    echo "======================================"
    echo -e "${NC}"
    
    # Parse command line arguments
    local machines_file=""
    local username=$(whoami)
    local max_parallel=5
    local test_only=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--username)
                username="$2"
                shift 2
                ;;
            -j|--jobs)
                max_parallel="$2"
                shift 2
                ;;
            -t|--test)
                test_only=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS] MACHINES_FILE"
                echo ""
                echo "Install the latest version of Go on CloudLab machines"
                echo ""
                echo "OPTIONS:"
                echo "  -u, --username USER    SSH username (default: current user)"
                echo "  -j, --jobs NUM         Max parallel installations (default: 5)"
                echo "  -t, --test            Only test existing installations"
                echo "  -h, --help            Show this help message"
                echo ""
                echo "MACHINES_FILE should contain one hostname per line"
                echo ""
                echo "Example:"
                echo "  $0 -u myuser -j 10 machines.txt"
                exit 0
                ;;
            *)
                if [ -z "$machines_file" ]; then
                    machines_file="$1"
                else
                    error "Unknown argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    if [ -z "$machines_file" ]; then
        error "Please provide a machines file"
        echo "Usage: $0 [OPTIONS] MACHINES_FILE"
        echo "Use -h for help"
        exit 1
    fi
    
    log "Configuration:"
    log "  Machines file: $machines_file"
    log "  Username: $username"
    log "  Max parallel jobs: $max_parallel"
    log "  Test only: $test_only"
    
    if [ "$test_only" = true ]; then
        test_installations "$machines_file" "$username"
    else
        get_latest_go_version
        install_go_parallel "$machines_file" "$username" "$max_parallel"
        echo ""
        test_installations "$machines_file" "$username"
    fi
    
    success "Script completed!"
}

# Run main function with all arguments
main "$@"
