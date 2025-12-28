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

# Step 2: Render the configuration file (idempotent)
echo "Rendering the configuration file..."
temp_config=$(mktemp)

SCRIPT_DIR=$(dirname "$0")
TEMPLATE_DIR="$SCRIPT_DIR/templates"
# shellcheck disable=SC2016
sed -e "s|@SERVICE_LINE@|SERVICE_UNIT=\"/etc/systemd/system/minecraft.service\"|g" \
    -e "s|@TMUX_PATH@|$(command -v tmux)|g" \
    -e "s|@JAVA_PATH@|$(command -v java)|g" \
    -e "s|@CHPST_PATH@|$(command -v chpst)|g" \
    -e 's|@RESOURCE_LIMIT_LINE@||g' \
    -e 's|@START_COMMAND_LINE@|START_COMMAND="$MINECRAFT_COMMAND"|g' \
    "$TEMPLATE_DIR/config.sh.in" >"$temp_config"

mv "$temp_config" "$CONFIG_FILE"
chown root:root "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# Source the configuration file
# shellcheck source=templates/config.sh.in
. "$CONFIG_FILE"

# Step 3: Create the Minecraft user and group
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

# Step 4: Download Minecraft server jar if not in -nodownload mode
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

# Step 5: Accept the Minecraft EULA
echo "Accepting the Minecraft EULA..."
if ! printf '%s\n' 'eula=true' | "$CHPST_PATH" -u "$MINECRAFT_USER" tee "$MINECRAFT_DIR/eula.txt" >/dev/null; then
    echo "Failed to write the Minecraft EULA. Exiting..."
    exit 1
fi

# Step 6: Copy the minecraft_service.sh script
echo "Copying the minecraft_service.sh script..."
cp minecraft_service.sh "$SERVICE_SCRIPT"

# Make the minecraft_service.sh script executable
chmod +x "$SERVICE_SCRIPT"

# Step 7: Create the systemd service unit
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

# Step 8: Reload systemd and enable the service
echo "Reloading systemd and enabling the Minecraft service..."
systemctl daemon-reload
systemctl enable minecraft.service

# Step 9: Create the monitoring script
echo "Creating the monitoring script..."
sed -e "s|@CONFIG_FILE@|$CONFIG_FILE|g" \
    -e 's|@LOG_COMMAND@|printf '\''%s\n'\'' "$*" | systemd-cat -t minecraft-monitor|g' \
    -e 's|@STATUS_COMMAND@|systemctl is-active --quiet minecraft.service|g' \
    -e 's|@START_COMMAND@|systemctl start minecraft.service|g' \
    "$TEMPLATE_DIR/monitor.sh.in" | tee "$MONITOR_SCRIPT" >/dev/null

# Make the monitoring script executable
chmod +x "$MONITOR_SCRIPT"

# Step 10: Create the restart script
echo "Creating the restart script..."
sed -e "s|@CONFIG_FILE@|$CONFIG_FILE|g" \
    -e 's|@LOG_COMMAND@|printf '\''%s\n'\'' "$*" | systemd-cat -t minecraft-restart|g' \
    -e 's|@RESTART_COMMAND@|systemctl restart minecraft.service|g' \
    "$TEMPLATE_DIR/restart.sh.in" | tee "$RESTART_SCRIPT" >/dev/null

# Make the restart script executable
chmod +x "$RESTART_SCRIPT"

# Step 11: Set up cron jobs without creating duplicates
echo "Setting up cron jobs..."
current_crontab=$(crontab -l 2>/dev/null || true)

monitor_cron="*/30 * * * * $MONITOR_SCRIPT"
restart_cron="0 4 * * * $RESTART_SCRIPT"

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
