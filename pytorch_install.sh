#!/bin/bash

# =================================================================
# Jetson Orin Nano PyTorch Auto-Installer
# =================================================================

# --- Colors for UI ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Global Variables ---
BASE_REPO_URL="https://pypi.jetson-ai-lab.io"
DOWNLOAD_DIR="$HOME/jetson_wheels"

# --- Helper Functions ---
log_step() { echo -e "\n${CYAN}[STEP]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

exit_on_error() {
    if [ $? -ne 0 ]; then
        log_error "$1"
        exit 1
    fi
}

# =================================================================
# PHASE 1: Strict System Detection
# =================================================================
clear
echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}   Jetson PyTorch Auto-Downloader (JP6 Only)${NC}"
echo -e "${CYAN}=======================================================${NC}"

log_step "Detecting JetPack and CUDA Versions..."

# --- 1. Detect Python ---
PY_MAJOR=$(python3 -c "import sys; print(sys.version_info.major)")
PY_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")
PY_TAG="cp${PY_MAJOR}${PY_MINOR}"
echo -e "Python Detected: ${GREEN}Python $PY_MAJOR.$PY_MINOR ($PY_TAG)${NC}"

# --- 2. Detect CUDA (Priority: nvidia-smi -> nvcc -> apt) ---
CUDA_VERSION=""

if command -v nvidia-smi &> /dev/null; then
    # Extract version, typically format is "12.6"
    CUDA_VERSION=$(nvidia-smi | grep "CUDA Version" | awk '{print $9}' | cut -d'.' -f1,2)
    echo -e "Detection Source: ${CYAN}nvidia-smi${NC}"
elif command -v nvcc &> /dev/null; then
    CUDA_VERSION=$(nvcc --version | grep "release" | awk '{print $6}' | cut -c2- | cut -d'.' -f1,2)
    echo -e "Detection Source: ${CYAN}nvcc${NC}"
else
    # Fallback: Try to infer from apt jetpack version (less reliable for cuda version)
    echo -e "Detection Source: ${YELLOW}apt-cache (Less Reliable)${NC}"
fi

if [ -z "$CUDA_VERSION" ]; then
    log_error "Could not detect CUDA version. Ensure JetPack is installed correctly."
    exit 1
fi

echo -e "CUDA Version Detected: ${GREEN}$CUDA_VERSION${NC}"

# --- 3. Detect JetPack (Major Version) ---
# We check apt-cache for nvidia-jetpack to ensure it is JetPack 6
JP_VERSION=$(apt-cache show nvidia-jetpack 2>/dev/null | grep "Version" | head -n 1 | awk '{print $2}' | cut -d'.' -f1)

if [ "$JP_VERSION" != "6" ]; then
    log_error "This script only supports JetPack 6."
    echo -e "Detected JetPack Version: ${RED}$JP_VERSION${NC}"
    echo "Please upgrade your Jetson or use a manual installation method."
    exit 1
fi

# --- 4. Strict Mapping Logic ---
# We strictly match the versions you provided: 12.6, 12.8, 12.9
REPO_PATH=""

case "$CUDA_VERSION" in
    "12.6")
        REPO_PATH="jp6/cu126"
        ;;
    "12.8")
        REPO_PATH="jp6/cu128"
        ;;
    "12.9")
        REPO_PATH="jp6/cu129"
        ;;
    *)
        log_error "Unsupported CUDA Version: $CUDA_VERSION"
        echo -e "This script only supports the following configurations:"
        echo -e "  - JetPack 6 with ${GREEN}CUDA 12.6${NC}"
        echo -e "  - JetPack 6 with ${GREEN}CUDA 12.8${NC}"
        echo -e "  - JetPack 6 with ${GREEN}CUDA 12.9${NC}"
        exit 1
        ;;
esac

FULL_REPO_URL="${BASE_REPO_URL}/${REPO_PATH}"
log_success "Configuration Validated: Targeting $REPO_PATH"


# =================================================================
# PHASE 2: Scraping the Repository
# =================================================================

log_step "Fetching available wheels from: $FULL_REPO_URL"

TEMP_HTML=$(mktemp)

wget -q -O "$TEMP_HTML" "$FULL_REPO_URL"
if [ $? -ne 0 ]; then
    log_error "Failed to access repository. Check internet connection."
    rm "$TEMP_HTML"
    exit 1
fi

# Filter for: .whl AND python_tag AND linux_aarch64
AVAILABLE_WHEELS=$(grep -o 'href="[^"]*"' "$TEMP_HTML" | cut -d'"' -f2 | grep ".whl" | grep "$PY_TAG" | grep "linux_aarch64" | sort -V -r)
rm "$TEMP_HTML"

if [ -z "$AVAILABLE_WHEELS" ]; then
    log_error "No matching wheels found for Python $PY_MAJOR.$PY_MINOR in $REPO_PATH."
    echo "This usually means the Python version in your environment doesn't match the wheels provided by NVIDIA."
    exit 1
fi

# =================================================================
# PHASE 3: User Selection
# =================================================================

log_step "Select a PyTorch wheel:"

IFS=$'\n' read -rd '' -a WHEEL_ARRAY <<< "$AVAILABLE_WHEELS"

i=1
for wheel in "${WHEEL_ARRAY[@]}"; do
    echo -e "$i) ${YELLOW}$wheel${NC}"
    ((i++))
done

read -p "Enter selection (Default 1): " selection
selection=${selection:-1}

if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#WHEEL_ARRAY[@]} ]; then
    log_error "Invalid selection."
    exit 1
fi

SELECTED_FILENAME="${WHEEL_ARRAY[$((selection-1))]}"
DOWNLOAD_URL="${FULL_REPO_URL}/${SELECTED_FILENAME}"

# =================================================================
# PHASE 4: Download & Install (Project Setup)
# =================================================================

mkdir -p "$DOWNLOAD_DIR"
DEST_FILE="$DOWNLOAD_DIR/$SELECTED_FILENAME"

log_step "Downloading..."
wget -q --show-progress -O "$DEST_FILE" "$DOWNLOAD_URL"
exit_on_error "Download failed."
log_success "Downloaded to $DEST_FILE"

# --- Project Setup ---
log_step "Project Setup"
read -p "Set up a virtual environment project now? (y/n): " setup_proj

if [[ "$setup_proj" =~ ^[Yy]$ ]]; then
    
    # Check for venv tool
    if ! dpkg -s python3-venv &> /dev/null; then
         log_warn "python3-venv is missing. Installing..."
         sudo apt update && sudo apt install -y python3-venv
         exit_on_error "Failed to install python3-venv."
    fi

    read -p "Enter full path for project directory: " PROJ_DIR
    
    if [ ! -d "$PROJ_DIR" ]; then
        mkdir -p "$PROJ_DIR"
    fi

    cd "$PROJ_DIR" || exit

    if [ -d ".venv" ]; then
        echo "Removing old .venv..."
        rm -rf .venv
    fi

    echo "Creating virtual environment..."
    python3 -m venv .venv
    VENV_PIP="$PROJ_DIR/.venv/bin/pip"

    # --- Critical Numpy Step ---
    echo "Installing Numpy 1.26.4..."
    $VENV_PIP install "numpy==1.26.4"
    exit_on_error "Numpy install failed."

    # --- Install Wheel ---
    echo "Installing PyTorch Wheel..."
    $VENV_PIP install "$DEST_FILE"
    exit_on_error "PyTorch install failed."

    # --- Requirements Fix ---
    if [ -f "requirements.txt" ]; then
        echo "Sanitizing requirements.txt..."
        cp requirements.txt requirements.bak
        sed -i '/numpy/d' requirements.txt
        sed -i '/torch/d' requirements.txt
        echo -e "numpy==1.26.4\n$(cat requirements.txt)" > requirements.txt
        
        echo "Installing remaining requirements..."
        $VENV_PIP install -r requirements.txt
    fi

    log_success "Setup Complete."
    echo -e "Activate with: ${CYAN}source $PROJ_DIR/.venv/bin/activate${NC}"
fi
