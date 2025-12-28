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

# Step 2: Render the configuration file (idempotent)
echo "Rendering the configuration file..."
temp_config=$(mktemp)

SCRIPT_DIR=$(dirname "$0")
TEMPLATE_DIR="$SCRIPT_DIR/templates"
# shellcheck disable=SC2016
sed -e "s|@SERVICE_LINE@|RC_SCRIPT=\"/usr/local/etc/rc.d/minecraft\"|g" \
    -e "s|@TMUX_PATH@|$(command -v tmux)|g" \
    -e "s|@JAVA_PATH@|$(command -v java)|g" \
    -e "s|@CHPST_PATH@|$(command -v chpst)|g" \
    -e 's|@RESOURCE_LIMIT_LINE@|RESOURCE_LIMIT_COMMAND="ulimit -u 256"|g' \
    -e 's|@START_COMMAND_LINE@|START_COMMAND="$RESOURCE_LIMIT_COMMAND && $MINECRAFT_COMMAND"|g' \
    "$TEMPLATE_DIR/config.sh.in" >"$temp_config"

mv "$temp_config" "$CONFIG_FILE"
chown root:wheel "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# Source the configuration file
# shellcheck source=templates/config.sh.in
. "$CONFIG_FILE"

# Step 3: Create the Minecraft user and group
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

# Step 7: Create the rc.d service script
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

# Step 8: Make the rc.d service script executable and enable the service
echo "Making the rc.d service script executable and enabling the Minecraft service..."
chmod +x "$RC_SCRIPT"
sysrc minecraft_enable="YES"

# Step 9: Create the monitoring script
echo "Creating the monitoring script..."
sed -e "s|@CONFIG_FILE@|$CONFIG_FILE|g" \
    -e 's|@LOG_COMMAND@|logger -t minecraft-monitor "$*"|g' \
    -e 's|@STATUS_COMMAND@|service minecraft status | grep -q "Minecraft server is running"|g' \
    -e 's|@START_COMMAND@|service minecraft start|g' \
    "$TEMPLATE_DIR/monitor.sh.in" | tee "$MONITOR_SCRIPT" >/dev/null

# Make the monitoring script executable
chmod +x "$MONITOR_SCRIPT"

# Step 10: Create the restart script
echo "Creating the restart script..."
sed -e "s|@CONFIG_FILE@|$CONFIG_FILE|g" \
    -e 's|@LOG_COMMAND@|logger -t minecraft-restart "$*"|g' \
    -e 's|@RESTART_COMMAND@|service minecraft restart|g' \
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
echo "You can start the Minecraft server with: sudo service minecraft start"
