#!/usr/bin/env bash
set -e

# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root. Use 'sudo -i'."
    exit 1
fi

SCRIPT_DIR="$HOME"
REPO_DIR="$SCRIPT_DIR/infernet-container-starter"

# Main menu
function main_menu() {
    while true; do
        clear
        echo -e "${CYAN}... (banner skipped for brevity)${NC}"
        echo -e "${GREEN}1) Install Ritual node${NC}"
        echo -e "${GREEN}2) View Ritual node logs${NC}"
        echo -e "${GREEN}3) Remove Ritual node${NC}"
        echo -e "${GREEN}4) Exit script${NC}"
        read -p "Enter choice: " choice

        case $choice in
            1) install_ritual_node ;;
            2) view_logs ;;
            3) remove_ritual_node ;;
            4) echo "Bye!"; exit 0 ;;
            *) echo "Invalid choice." ;;
        esac

        read -n 1 -s -r -p "Press any key to return to menu..."
    done
}

function install_ritual_node() {
    echo "[+] Updating system..."
    apt update && apt upgrade -y
    apt install -y curl git jq lz4 build-essential screen python3 python3-pip docker.io

    systemctl enable --now docker

    echo "[+] Installing pip & Python packages..."
    pip3 install --upgrade pip infernet-cli infernet-client

    # Docker Compose installation
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
        curl -L "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-$(uname -s)-$(uname -m)" \
             -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        mkdir -p ~/.docker/cli-plugins
        curl -SL https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-linux-x86_64 \
            -o ~/.docker/cli-plugins/docker-compose
        chmod +x ~/.docker/cli-plugins/docker-compose
    fi

    echo "[+] Installing Foundry..."
    mkdir -p ~/foundry && cd ~/foundry
    curl -L https://foundry.paradigm.xyz | bash
    ~/.foundry/bin/foundryup
    export PATH="$HOME/.foundry/bin:$PATH"
    which forge || { echo "Foundry failed to install."; exit 1; }

    rm -f /usr/bin/forge 2>/dev/null || true

    echo "[+] Cloning repo..."
    cd "$SCRIPT_DIR"
    rm -rf "$REPO_DIR"
    git clone https://github.com/ritual-net/infernet-container-starter "$REPO_DIR"
    cd "$REPO_DIR"

    docker pull ritualnetwork/hello-world-infernet:latest

    if screen -list | grep -q "ritual"; then
        screen -S ritual -X quit
    fi

    screen -S ritual -dm bash -c 'project=hello-world make deploy-container; exec bash'

    echo
    read -p "Enter your Private Key (0x...): " PRIVATE_KEY

    # Use safe sed replacements
    CONFIG1="$REPO_DIR/deploy/config.json"
    CONFIG2="$REPO_DIR/projects/hello-world/container/config.json"

    for file in "$CONFIG1" "$CONFIG2"; do
        [[ -f "$file" ]] || continue
        sed -i "s|\"private_key\": \".*\"|\"private_key\": \"$PRIVATE_KEY\"|" "$file"
        sed -i "s|\"registry_address\": \".*\"|\"registry_address\": \"0x3B1554f346DFe5c482Bb4BA31b880c1C18412170\"|" "$file"
        sed -i 's|"rpc_url": ".*"|"rpc_url": "https://base.drpc.org"|' "$file"
        sed -i "s|\"sleep\": .*|\"sleep\": 3|" "$file"
        sed -i "s|\"starting_sub_id\": .*|\"starting_sub_id\": 244000|" "$file"
        sed -i "s|\"batch_size\": .*|\"batch_size\": 50|" "$file"
        sed -i "s|\"sync_period\": .*|\"sync_period\": 30|" "$file"
    done

    echo "[+] Restarting Docker containers..."
    docker compose -f deploy/docker-compose.yaml down || docker-compose -f deploy/docker-compose.yaml down
    docker compose -f deploy/docker-compose.yaml up -d || docker-compose -f deploy/docker-compose.yaml up -d

    echo "[+] Installing Forge dependencies..."
    cd "$REPO_DIR/projects/hello-world/contracts"
    rm -rf lib/forge-std lib/infernet-sdk
    forge install foundry-rs/forge-std
    forge install ritual-net/infernet-sdk

    echo "[+] Deploying contracts..."
    cd "$REPO_DIR"
    DEPLOY_OUTPUT=$(project=hello-world make deploy-contracts 2>&1)
    echo "$DEPLOY_OUTPUT"

    NEW_ADDR=$(echo "$DEPLOY_OUTPUT" | grep -oP 'Deployed SaysHello:\s+\K0x[0-9a-fA-F]{40}')
    if [[ -n "$NEW_ADDR" ]]; then
        sed -i "s|SaysGM saysGm = SaysGM(0x[0-9a-fA-F]\+);|SaysGM saysGm = SaysGM($NEW_ADDR);|" \
            projects/hello-world/contracts/script/CallContract.s.sol
        project=hello-world make call-contract
    else
        echo "[!] Contract address not found!"
    fi

    echo "[+] Running diyujiedian.sh in background..."
    wget -q -O /root/diyujiedian.sh https://raw.githubusercontent.com/ydk1191120641/Ritual/refs/heads/main/diyujiedian.sh
    chmod +x /root/diyujiedian.sh
    screen -S diyujiedian -X quit 2>/dev/null || true
    screen -S diyujiedian -dm bash -c '/root/diyujiedian.sh; exec bash'

    echo "[✓] Setup complete!"
}

function view_logs() {
    docker logs -f infernet-node
}

function remove_ritual_node() {
    echo "[!] Removing Ritual node..."
    cd "$SCRIPT_DIR/infernet-container-starter" || return
    docker compose down || docker-compose down
    rm -rf "$SCRIPT_DIR/infernet-container-starter"
    docker rmi ritualnetwork/hello-world-infernet:latest || true
    echo "[✓] Ritual node removed."
}

main_menu
