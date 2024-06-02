#!/bin/sh

# Exit on errors and undefined variables
set -eu

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
sudo pkg update
sudo pkg install -y tmux openjdk22 wget

# Check if necessary commands are available
command -v tmux >/dev/null 2>&1 || {
    echo "tmux is required but it's not installed. Aborting." >&2
    exit 1
}
command -v java >/dev/null 2>&1 || {
    echo "java is required but it's not installed. Aborting." >&2
    exit 1
}
command -v wget >/dev/null 2>&1 || {
    echo "wget is required but it's not installed. Aborting." >&2
    exit 1
}

# Step 2: Append necessary paths to the local configuration file
echo "Appending necessary paths to the configuration file..."
{
    echo 'SERVICE_SCRIPT="/usr/local/etc/rc.d/minecraft"'
    echo "TMUX_PATH=$(command -v tmux)"
    echo "JAVA_PATH=$(command -v java)"
    echo "MINECRAFT_COMMAND=\"\$JAVA_PATH -Xmx\$MEMORY_ALLOCATION -Xms\$INITIAL_MEMORY -jar \$MINECRAFT_JAR nogui\""
} >>"$LOCAL_CONFIG_FILE"

# Step 3: Copy the configuration file
echo "Copying the configuration file..."
sudo cp "$LOCAL_CONFIG_FILE" "$CONFIG_FILE"
sudo chown root:wheel "$CONFIG_FILE"
sudo chmod 644 "$CONFIG_FILE"

# Source the configuration file
# shellcheck source=minecraft_config.sh
. "$CONFIG_FILE"

# Step 4: Create the Minecraft user and directory
if ! id -u "$MINECRAFT_USER" >/dev/null 2>&1; then
    echo "Creating Minecraft user..."
    sudo pw user add "$MINECRAFT_USER" -m -s /bin/sh -c "Minecraft Server User"
else
    echo "User $MINECRAFT_USER already exists."
fi

if ! getent group "$MINECRAFT_GROUP" >/dev/null 2>&1; then
    sudo pw groupadd "$MINECRAFT_GROUP"
fi

if [ ! -d "$MINECRAFT_DIR" ]; then
    echo "Creating Minecraft server directory..."
    sudo mkdir -p "$MINECRAFT_DIR"
    sudo chown -R "$MINECRAFT_USER":"$MINECRAFT_GROUP" "$MINECRAFT_DIR"
else
    echo "Minecraft server directory already exists."
fi

# Step 5: Download Minecraft server jar if not in -nodownload mode
if [ $NODOWNLOAD -eq 0 ]; then
    echo "Please enter the download URL for the Minecraft server jar:"
    read -r DOWNLOAD_URL

    echo "Downloading Minecraft server jar..."
    if ! su -m "$MINECRAFT_USER" -c "wget -O $MINECRAFT_DIR/$MINECRAFT_JAR $DOWNLOAD_URL"; then
        echo "Failed to download the Minecraft server jar. Exiting..."
        exit 1
    fi
else
    echo "Skipping download of Minecraft server jar due to -nodownload option."
fi

# Step 6: Accept the Minecraft EULA
echo "Accepting the Minecraft EULA..."
su -m "$MINECRAFT_USER" -c "echo 'eula=true' > $MINECRAFT_DIR/eula.txt"

# Step 7: Copy the minecraft_service.sh script
echo "Copying the minecraft_service.sh script..."
sudo cp minecraft_service.sh "$SERVICE_SH"

# Make the minecraft_service.sh script executable
sudo chmod +x "$SERVICE_SH"

# Step 8: Create the rc.d service script
echo "Creating the rc.d service script..."
sudo tee "$SERVICE_SCRIPT" >/dev/null <<EOF
#!/bin/sh

# PROVIDE: minecraft
# REQUIRE: LOGIN
# KEYWORD: shutdown

. /etc/rc.subr

name="minecraft"
rcvar=minecraft_enable

load_rc_config \$name

: \${minecraft_enable:="NO"}
: \${minecraft_user:="$MINECRAFT_USER"}
: \${minecraft_group:="$MINECRAFT_GROUP"}
: \${minecraft_dir:="$MINECRAFT_DIR"}
: \${service_sh:="$SERVICE_SH"}

start_cmd="\$service_sh start"
stop_cmd="\$service_sh stop"
status_cmd="\$service_sh status"
log_cmd="\$service_sh log"
attach_cmd="\$service_sh attach"
cmd_cmd="\$service_sh cmd"
reload_cmd="\$service_sh reload"
extra_commands="log attach cmd reload"

run_rc_command "\$1"
EOF

# Step 9: Make the rc.d service script executable and enable the service
echo "Making the rc.d service script executable and enabling the Minecraft service..."
sudo chmod +x "$SERVICE_SCRIPT"
sudo sysrc minecraft_enable="YES"

# Step 10: Create the monitoring script
echo "Creating the monitoring script..."
sudo tee "$MONITOR_SCRIPT" >/dev/null <<EOF
#!/bin/sh

# Source the configuration file
. "$CONFIG_FILE"

# Check the status of the Minecraft server
if ! service minecraft status | grep -q "Minecraft server is running"; then
    echo "\$(date): Minecraft server is down. Restarting..."
    service minecraft start
    echo "\$(date): Minecraft server started."
else
    echo "\$(date): Minecraft server is running."
fi
EOF

# Make the monitoring script executable
sudo chmod +x "$MONITOR_SCRIPT"

# Step 11: Create the restart script
echo "Creating the restart script..."
sudo tee "$RESTART_SCRIPT" >/dev/null <<EOF
#!/bin/sh

# Source the configuration file
. "$CONFIG_FILE"

echo "\$(date): Restarting Minecraft server..."
service minecraft stop
sleep 20  # Wait for 20 seconds to ensure the server has stopped completely
service minecraft start
echo "\$(date): Minecraft server restarted."
EOF

# Make the restart script executable
sudo chmod +x "$RESTART_SCRIPT"

# Step 12: Set up cron jobs without creating duplicates
echo "Setting up cron jobs..."
current_crontab=$(sudo crontab -l 2>/dev/null || true)

monitor_cron="*/30 * * * * $MONITOR_SCRIPT >> /var/log/minecraft_monitor.log 2>&1"
restart_cron="0 4 * * * $RESTART_SCRIPT >> /var/log/minecraft_restart.log 2>&1"

temp_crontab=$(mktemp)

# Copy existing crontab to temp file
echo "$current_crontab" >"$temp_crontab"

# Only add the monitor cron job if it doesn't already exist
if ! grep -q "$MONITOR_SCRIPT" "$temp_crontab"; then
    echo "$monitor_cron" >>"$temp_crontab"
else
    echo "Monitor cron job already exists. Skipping..."
fi

# Only add the restart cron job if it doesn't already exist
if ! grep -q "$RESTART_SCRIPT" "$temp_crontab"; then
    echo "$restart_cron" >>"$temp_crontab"
else
    echo "Restart cron job already exists. Skipping..."
fi

# Install the new crontab
sudo crontab "$temp_crontab"

# Clean up
rm "$temp_crontab"

echo "Setup complete. The Minecraft server is installed, but it is not yet started."
echo "You can start the Minecraft server with: sudo service minecraft start"
