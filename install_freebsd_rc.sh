#!/bin/sh
# install_freebsd_rc.sh – Installer for Minecraft server on FreeBSD using rc.d

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
pkg update
pkg install -y tmux openjdk17 curl runit

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
    echo 'RC_SCRIPT="/usr/local/etc/rc.d/minecraft"'
    echo "TMUX_PATH=$(command -v tmux)"
    echo "JAVA_PATH=$(command -v java)"
    echo "CHPST_PATH=$(command -v chpst)"
    echo 'RESOURCE_LIMIT_COMMAND="ulimit -u 256"'
    # shellcheck disable=SC2016
    echo 'MINECRAFT_COMMAND="exec $JAVA_PATH -Xmx$MEMORY_ALLOCATION -Xms$MEMORY_ALLOCATION -XX:+UseShenandoahGC -XX:+UseNUMA -XX:+AlwaysPreTouch -XX:+UseStringDeduplication -XX:+OptimizeStringConcat -jar $MINECRAFT_JAR nogui"'
    # shellcheck disable=SC2016
    echo 'START_COMMAND="$RESOURCE_LIMIT_COMMAND && $MINECRAFT_COMMAND"'
    echo "$CONFIG_BLOCK_END"
} >>"$temp_config"

mv "$temp_config" "$CONFIG_FILE"
chown root:wheel "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# Source the configuration file
# shellcheck source=minecraft_config.sh
. "$CONFIG_FILE"

# Step 4: Create the Minecraft user and group
if ! id -u "$MINECRAFT_USER" >/dev/null 2>&1; then
    echo "Creating Minecraft user..."
    pw useradd -n "$MINECRAFT_USER" -s /bin/sh -d "$MINECRAFT_DIR" -c "Minecraft Server User" -m -w no -q
else
    echo "User $MINECRAFT_USER already exists."
fi

# Check if the group exists and add the user to it
if ! getent group "$MINECRAFT_GROUP" >/dev/null 2>&1; then
    echo "Creating Minecraft group and adding user to it..."
    pw groupadd "$MINECRAFT_GROUP" -q
    pw groupmod "$MINECRAFT_GROUP" -m "$MINECRAFT_USER" -q
else
    echo "Group $MINECRAFT_GROUP already exists. Adding user to group..."
    pw groupmod "$MINECRAFT_GROUP" -m "$MINECRAFT_USER" -q
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

# Step 8: Create the rc.d service script
echo "Creating the rc.d service script..."
tee "$RC_SCRIPT" >/dev/null <<EOF
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
: \${service_script:="$SERVICE_SCRIPT"}

start_cmd="\$service_script start"
stop_cmd="\$service_script stop"
status_cmd="\$service_script status"
log_cmd="\$service_script log"
attach_cmd="\$service_script attach"
cmd_cmd="\$service_script cmd"
reload_cmd="\$service_script reload"
extra_commands="log attach cmd reload"

run_rc_command "\$@"
EOF

# Step 9: Make the rc.d service script executable and enable the service
echo "Making the rc.d service script executable and enabling the Minecraft service..."
chmod +x "$RC_SCRIPT"
sysrc minecraft_enable="YES"

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
if ! service minecraft status | grep -q "Minecraft server is running"; then
    echo "\$(date): Minecraft server is down. Restarting..."
    service minecraft start
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
service minecraft restart
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
echo "You can start the Minecraft server with: sudo service minecraft start"
