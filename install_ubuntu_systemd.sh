#!/bin/sh
# install_ubuntu_systemd.sh – Installer for Minecraft server on Debian/Ubuntu using systemd

# Exit on errors and undefined variables
set -eu

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or run as root user."
    exit 1
fi

# Define the location of the config file
CONFIG_FILE="/etc/minecraft_config.sh"
LOCAL_CONFIG_FILE="minecraft_config.sh"

# Check for -nodownload option
NODOWNLOAD=0
for arg in "$@"; do
    case $arg in
    -nodownload)
        NODOWNLOAD=1
        shift
        ;;
    esac
done

# Step 1: Install necessary packages
echo "Installing necessary packages..."
apt update
apt install -y tmux openjdk-17-jdk-headless curl runit

# Verify required commands are available
for cmd in tmux java curl chpst; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "$cmd is required but not installed. Exiting."
        exit 1
    }
done

# Step 2: Ensure the configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Copying the configuration file..."
    cp "$LOCAL_CONFIG_FILE" "$CONFIG_FILE"
fi

# Step 3: Update necessary paths in the configuration file (idempotent)
echo "Updating necessary paths in the configuration file..."
CONFIG_BLOCK_START="# BEGIN MINECRAFT INSTALLER AUTO-CONFIG"
CONFIG_BLOCK_END="# END MINECRAFT INSTALLER AUTO-CONFIG"
temp_config=$(mktemp)

awk -v start="$CONFIG_BLOCK_START" -v end="$CONFIG_BLOCK_END" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
' "$CONFIG_FILE" >"$temp_config"

{
    echo "$CONFIG_BLOCK_START"
    echo 'SERVICE_UNIT="/etc/systemd/system/minecraft.service"'
    echo "TMUX_PATH=$(command -v tmux)"
    echo "JAVA_PATH=$(command -v java)"
    echo "CHPST_PATH=$(command -v chpst)"
    # shellcheck disable=SC2016
    echo 'MINECRAFT_COMMAND="exec $JAVA_PATH -Xmx$MEMORY_ALLOCATION -Xms$MEMORY_ALLOCATION -XX:+UseShenandoahGC -XX:+UseNUMA -XX:+AlwaysPreTouch -XX:+UseStringDeduplication -XX:+OptimizeStringConcat -jar $MINECRAFT_JAR nogui"'
    # shellcheck disable=SC2016
    echo 'START_COMMAND="$MINECRAFT_COMMAND"'
    echo "$CONFIG_BLOCK_END"
} >>"$temp_config"

mv "$temp_config" "$CONFIG_FILE"
chown root:root "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# Source the configuration file
# shellcheck source=minecraft_config.sh
. "$CONFIG_FILE"

# Step 4: Create the Minecraft user and group
if ! id -u "$MINECRAFT_USER" >/dev/null 2>&1; then
    echo "Creating Minecraft user..."
    adduser --system --home "$MINECRAFT_DIR" --shell /bin/sh --disabled-login --group --gecos "Minecraft Server User" "$MINECRAFT_USER"
else
    echo "User $MINECRAFT_USER already exists."
fi

# Check if the group exists and add the user to it
if ! getent group "$MINECRAFT_GROUP" >/dev/null 2>&1; then
    echo "Creating Minecraft group and adding user to it..."
    groupadd "$MINECRAFT_GROUP"
    usermod -aG "$MINECRAFT_GROUP" "$MINECRAFT_USER"
else
    echo "Group $MINECRAFT_GROUP already exists. Adding user to group..."
    usermod -aG "$MINECRAFT_GROUP" "$MINECRAFT_USER"
fi

# Ensure the Minecraft server directory exists and is owned by the Minecraft user and group
if [ ! -d "$MINECRAFT_DIR" ]; then
    echo "Creating Minecraft server directory..."
    mkdir -p "$MINECRAFT_DIR"
fi

echo "Setting ownership of the Minecraft server directory..."
chown -R "$MINECRAFT_USER":"$MINECRAFT_GROUP" "$MINECRAFT_DIR"
chmod 755 "$MINECRAFT_DIR"

# Step 5: Download Minecraft server jar if not in -nodownload mode
if [ $NODOWNLOAD -eq 0 ]; then
    echo "Please enter the download URL for the Minecraft server jar:"
    read -r DOWNLOAD_URL

    echo "Downloading Minecraft server jar..."
    if ! "$CHPST_PATH" -u "$MINECRAFT_USER" curl -fLo "$MINECRAFT_DIR/$MINECRAFT_JAR" "$DOWNLOAD_URL"; then
        echo "Failed to download the Minecraft server jar. Exiting..."
        exit 1
    fi
else
    echo "Skipping download of Minecraft server jar due to -nodownload option."
fi

# Step 6: Accept the Minecraft EULA
echo "Accepting the Minecraft EULA..."
if ! printf '%s\n' 'eula=true' | "$CHPST_PATH" -u "$MINECRAFT_USER" tee "$MINECRAFT_DIR/eula.txt" >/dev/null; then
    echo "Failed to write the Minecraft EULA. Exiting..."
    exit 1
fi

# Step 7: Copy the minecraft_service.sh script
echo "Copying the minecraft_service.sh script..."
cp minecraft_service.sh "$SERVICE_SCRIPT"

# Make the minecraft_service.sh script executable
chmod +x "$SERVICE_SCRIPT"

# Step 8: Create the systemd service unit
echo "Creating the systemd service unit..."
tee "$SERVICE_UNIT" >/dev/null <<EOF
[Unit]
Description=Minecraft Server

Wants=network.target
After=network.target

[Service]
Type=forking
User=$MINECRAFT_USER
Group=$MINECRAFT_GROUP
Nice=5
TimeoutStopSec=90

ProtectHome=read-only
ProtectSystem=full
NoNewPrivileges=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictRealtime=yes
SystemCallFilter=@system-service
PrivateDevices=yes

LimitNPROC=256
MemoryMax=$MEMORY_ALLOCATION

WorkingDirectory=$MINECRAFT_DIR
PIDFile=$PID_PATH
ExecStart=$SERVICE_SCRIPT start
ExecReload=$SERVICE_SCRIPT reload
ExecStop=$SERVICE_SCRIPT stop

# No private /tmp or else the tmux socket/session inside can't be attached externally
PrivateTmp=no

Restart=on-failure
RestartSec=20s

[Install]
WantedBy=multi-user.target
EOF

# Step 9: Reload systemd and enable the service
echo "Reloading systemd and enabling the Minecraft service..."
systemctl daemon-reload
systemctl enable minecraft.service

# Step 10: Create the monitoring script
echo "Creating the monitoring script..."
tee "$MONITOR_SCRIPT" >/dev/null <<EOF
#!/bin/sh

# Exit on errors and undefined variables
set -eu

# Ensure the script is run as root
if [ "\$(id -u)" -ne 0 ]; then
    echo "\$(date): This script must be run as root. Use sudo or run as root."
    exit 1
fi

# Source the configuration file
. "$CONFIG_FILE"

# Check the status of the Minecraft server
if ! systemctl is-active --quiet minecraft.service; then
    echo "\$(date): Minecraft server is down. Restarting..."
    systemctl start minecraft.service
    echo "\$(date): Minecraft server started."
else
    echo "\$(date): Minecraft server is running."
fi
EOF

# Make the monitoring script executable
chmod +x "$MONITOR_SCRIPT"

# Step 11: Create the restart script
echo "Creating the restart script..."
tee "$RESTART_SCRIPT" >/dev/null <<EOF
#!/bin/sh

# Exit on errors and undefined variables
set -eu

# Ensure the script is run as root
if [ "\$(id -u)" -ne 0 ]; then
    echo "\$(date): This script must be run as root. Use sudo or run as root."
    exit 1
fi

# Source the configuration file
. "$CONFIG_FILE"

echo "\$(date): Restarting Minecraft server..."
systemctl restart minecraft.service
echo "\$(date): Minecraft server restarted."
EOF

# Make the restart script executable
chmod +x "$RESTART_SCRIPT"

# Step 12: Set up cron jobs without creating duplicates
echo "Setting up cron jobs..."
current_crontab=$(crontab -l 2>/dev/null || true)

monitor_cron="*/30 * * * * $MONITOR_SCRIPT >>/var/log/minecraft_monitor.log 2>&1"
restart_cron="0 4 * * * $RESTART_SCRIPT >>/var/log/minecraft_restart.log 2>&1"

temp_crontab=$(mktemp)

# Copy existing crontab to temp file
echo "$current_crontab" >"$temp_crontab"

for cron_entry in \
    "$MONITOR_SCRIPT|$monitor_cron" \
    "$RESTART_SCRIPT|$restart_cron"; do
    script_path=${cron_entry%%|*}
    cron_line=${cron_entry#*|}
    if ! grep -q "$script_path" "$temp_crontab"; then
        echo "$cron_line" >>"$temp_crontab"
    else
        echo "Cron job for $script_path already exists. Skipping..."
    fi
done

# Install the new crontab
crontab "$temp_crontab"

# Clean up
rm "$temp_crontab"

echo "Setup complete. The Minecraft server is installed, but it is not yet started."
echo "You can start the Minecraft server with: sudo systemctl start minecraft.service"
