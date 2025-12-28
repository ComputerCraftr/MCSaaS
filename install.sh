#!/bin/sh
# install.sh – Installer for Minecraft server on Ubuntu/FreeBSD

# Exit on errors and undefined variables
set -eu

usage() {
    echo "Usage: $0 --os {Ubuntu|FreeBSD} [-nodl]"
    echo "  --os        Target OS (Ubuntu or FreeBSD)"
    echo "  --url URL   Download URL for the Minecraft server jar"
    echo "  -nodl       Skip downloading the Minecraft server jar"
    echo "  -h, --help  Show this help message"
}

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or run as root user."
    exit 1
fi

OS=""
DOWNLOAD=1
DOWNLOAD_URL=""
while [ $# -gt 0 ]; do
    case "$1" in
    --os)
        OS="$2"
        shift 2
        ;;
    --url)
        DOWNLOAD_URL="$2"
        shift 2
        ;;
    -nodl)
        DOWNLOAD=0
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
done

if [ -z "$OS" ]; then
    echo "Missing required --os flag."
    usage
    exit 1
fi

OS_INPUT="$OS"
OS=$(printf '%s' "$OS" | tr '[:upper:]' '[:lower:]')

if [ "$DOWNLOAD" -eq 0 ] && [ -n "$DOWNLOAD_URL" ]; then
    echo "Cannot use --url with -nodl."
    usage
    exit 1
fi

case "$OS" in
ubuntu | freebsd) ;;
*)
    echo "Unsupported OS: $OS_INPUT"
    usage
    exit 1
    ;;
esac

# Define the location of the config file
CONFIG_FILE="/etc/minecraftcfg"

SCRIPT_DIR=$(dirname "$0")
TEMPLATE_DIR="$SCRIPT_DIR/templates"

escape_sed_replacement() {
    # Escape replacement strings so sed does not treat them as delimiters or & expansions.
    printf '%s' "$1" | sed 's/[\\/|&]/\\&/g'
}

group_exists() {
    getent group "$1" >/dev/null 2>&1
}

user_exists() {
    id -u "$1" >/dev/null 2>&1
}

add_group() {
    name="$1"
    case "$OS" in
    ubuntu) groupadd "$name" ;;
    freebsd) pw groupadd -n "$name" -q ;;
    esac
}

add_user() {
    name="$1"
    case "$OS" in
    ubuntu)
        adduser --system --shell /bin/sh --home "$MINECRAFT_DIR" --gecos "Minecraft Server User" \
            --ingroup "$MINECRAFT_GROUP" --disabled-login "$name"
        ;;
    freebsd)
        pw useradd -n "$name" -s /bin/sh -d "$MINECRAFT_DIR" -m -c "Minecraft Server User" \
            -g "$MINECRAFT_GROUP" -w no -q
        ;;
    esac
}

add_user_to_group() {
    user="$1"
    group="$2"
    case "$OS" in
    ubuntu) usermod -aG "$group" "$user" ;;
    freebsd) pw groupmod -n "$group" -m "$user" -q ;;
    esac
}

install_packages() {
    case "$OS" in
    ubuntu)
        apt update
        apt install -y tmux openjdk-17-jdk-headless curl runit
        ;;
    freebsd)
        pkg update
        pkg install -y tmux openjdk17 curl runit
        ;;
    esac
}

enable_service() {
    case "$OS" in
    ubuntu)
        systemctl daemon-reload
        systemctl enable minecraft.service
        ;;
    freebsd)
        sysrc minecraft_enable="YES"
        ;;
    esac
}

start_message() {
    case "$OS" in
    ubuntu) echo "You can start the Minecraft server with: sudo systemctl start minecraft.service" ;;
    freebsd) echo "You can start the Minecraft server with: sudo service minecraft start" ;;
    esac
}

# Step 1: Install necessary packages
echo "Installing necessary packages..."
install_packages

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

CONFIG_OWNER="root:$(id -gn 0)"
case "$OS" in
freebsd)
    SERVICE_LINE='RC_SCRIPT="/usr/local/etc/rc.d/minecraft"'
    RESOURCE_LIMIT_LINE='RESOURCE_LIMIT_COMMAND="ulimit -u 256"'
    # shellcheck disable=SC2016
    START_COMMAND_LINE='START_COMMAND="$RESOURCE_LIMIT_COMMAND && $MINECRAFT_COMMAND"'
    ;;
ubuntu)
    SERVICE_LINE='SERVICE_UNIT="/etc/systemd/system/minecraft.service"'
    RESOURCE_LIMIT_LINE=""
    # shellcheck disable=SC2016
    START_COMMAND_LINE='START_COMMAND="$MINECRAFT_COMMAND"'
    ;;
esac

TMUX_PATH=$(command -v tmux)
JAVA_PATH=$(command -v java)
CHPST_PATH=$(command -v chpst)

ESC_SERVICE_LINE=$(escape_sed_replacement "$SERVICE_LINE")
ESC_TMUX_PATH=$(escape_sed_replacement "$TMUX_PATH")
ESC_JAVA_PATH=$(escape_sed_replacement "$JAVA_PATH")
ESC_CHPST_PATH=$(escape_sed_replacement "$CHPST_PATH")
ESC_RESOURCE_LIMIT_LINE=$(escape_sed_replacement "$RESOURCE_LIMIT_LINE")
ESC_START_COMMAND_LINE=$(escape_sed_replacement "$START_COMMAND_LINE")

sed -e "s|@SERVICE_LINE@|$ESC_SERVICE_LINE|g" \
    -e "s|@TMUX_PATH@|$ESC_TMUX_PATH|g" \
    -e "s|@JAVA_PATH@|$ESC_JAVA_PATH|g" \
    -e "s|@CHPST_PATH@|$ESC_CHPST_PATH|g" \
    -e "s|@RESOURCE_LIMIT_LINE@|$ESC_RESOURCE_LIMIT_LINE|g" \
    -e "s|@START_COMMAND_LINE@|$ESC_START_COMMAND_LINE|g" \
    "$TEMPLATE_DIR/config.sh.in" >"$temp_config"

mv "$temp_config" "$CONFIG_FILE"
chown "$CONFIG_OWNER" "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# Source the configuration file
# shellcheck source=templates/config.sh.in
. "$CONFIG_FILE"

# Step 3: Create the Minecraft user and group
if ! group_exists "$MINECRAFT_GROUP"; then
    echo "Creating Minecraft group..."
    add_group "$MINECRAFT_GROUP"
else
    echo "Group $MINECRAFT_GROUP already exists."
fi

if ! user_exists "$MINECRAFT_USER"; then
    echo "Creating Minecraft user..."
    add_user "$MINECRAFT_USER"
else
    echo "User $MINECRAFT_USER already exists."
fi

echo "Adding user to group..."
add_user_to_group "$MINECRAFT_USER" "$MINECRAFT_GROUP"

# Ensure the Minecraft server directory exists and is owned by the Minecraft user and group
if [ ! -d "$MINECRAFT_DIR" ]; then
    echo "Creating Minecraft server directory..."
    mkdir -p "$MINECRAFT_DIR"
fi

echo "Setting ownership of the Minecraft server directory..."
chown -R "$MINECRAFT_USER":"$MINECRAFT_GROUP" "$MINECRAFT_DIR"
chmod 755 "$MINECRAFT_DIR"

# Step 4: Download Minecraft server jar if not in -nodl mode
if [ $DOWNLOAD -ne 0 ]; then
    if [ -z "$DOWNLOAD_URL" ]; then
        echo "Please enter the download URL for the Minecraft server jar:"
        read -r DOWNLOAD_URL
    fi

    echo "Downloading Minecraft server jar..."
    if ! "$CHPST_PATH" -u "$MINECRAFT_USER" curl -fLo "$MINECRAFT_DIR/$MINECRAFT_JAR" "$DOWNLOAD_URL"; then
        echo "Failed to download the Minecraft server jar. Exiting..."
        exit 1
    fi
else
    echo "Skipping download of Minecraft server jar due to -nodl option."
fi

# Step 5: Accept the Minecraft EULA
echo "Accepting the Minecraft EULA..."
if ! printf '%s\n' 'eula=true' | "$CHPST_PATH" -u "$MINECRAFT_USER" tee "$MINECRAFT_DIR/eula.txt" >/dev/null; then
    echo "Failed to write the Minecraft EULA. Exiting..."
    exit 1
fi

# Step 6: Copy the minecraft_service.sh script
echo "Copying the minecraft_service.sh script..."
cp "$SCRIPT_DIR/minecraft_service.sh" "$SERVICE_SCRIPT"

# Make the minecraft_service.sh script executable
chmod +x "$SERVICE_SCRIPT"

# Step 7: Create the service definition
echo "Creating the service definition..."
ESC_MINECRAFT_USER=$(escape_sed_replacement "$MINECRAFT_USER")
ESC_MINECRAFT_GROUP=$(escape_sed_replacement "$MINECRAFT_GROUP")
ESC_MINECRAFT_DIR=$(escape_sed_replacement "$MINECRAFT_DIR")
ESC_MEMORY_ALLOCATION=$(escape_sed_replacement "$MEMORY_ALLOCATION")
ESC_PID_PATH=$(escape_sed_replacement "$PID_PATH")
ESC_SERVICE_SCRIPT=$(escape_sed_replacement "$SERVICE_SCRIPT")

case "$OS" in
freebsd)
    sed -e "s|@MINECRAFT_USER@|$ESC_MINECRAFT_USER|g" \
        -e "s|@MINECRAFT_GROUP@|$ESC_MINECRAFT_GROUP|g" \
        -e "s|@MINECRAFT_DIR@|$ESC_MINECRAFT_DIR|g" \
        -e "s|@SERVICE_SCRIPT@|$ESC_SERVICE_SCRIPT|g" \
        "$TEMPLATE_DIR/rc.d.in" | tee "$RC_SCRIPT" >/dev/null
    chmod +x "$RC_SCRIPT"
    ;;
ubuntu)
    sed -e "s|@MINECRAFT_USER@|$ESC_MINECRAFT_USER|g" \
        -e "s|@MINECRAFT_GROUP@|$ESC_MINECRAFT_GROUP|g" \
        -e "s|@MINECRAFT_DIR@|$ESC_MINECRAFT_DIR|g" \
        -e "s|@MEMORY_ALLOCATION@|$ESC_MEMORY_ALLOCATION|g" \
        -e "s|@PID_PATH@|$ESC_PID_PATH|g" \
        -e "s|@SERVICE_SCRIPT@|$ESC_SERVICE_SCRIPT|g" \
        "$TEMPLATE_DIR/minecraft.service.in" | tee "$SERVICE_UNIT" >/dev/null
    ;;
esac

# Step 8: Enable the service
echo "Enabling the Minecraft service..."
enable_service

# Step 9: Create the monitoring script
echo "Creating the monitoring script..."
case "$OS" in
freebsd)
    LOG_COMMAND='logger -t minecraft-monitor "$*"'
    STATUS_COMMAND='service minecraft status | grep -q "Minecraft server is running"'
    START_COMMAND='service minecraft start'
    ;;
ubuntu)
    LOG_COMMAND='printf "%s\n" "$*" | systemd-cat -t minecraft-monitor'
    STATUS_COMMAND='systemctl is-active --quiet minecraft.service'
    START_COMMAND='systemctl start minecraft.service'
    ;;
esac

sed -e "s|@CONFIG_FILE@|$(escape_sed_replacement "$CONFIG_FILE")|g" \
    -e "s|@LOG_COMMAND@|$(escape_sed_replacement "$LOG_COMMAND")|g" \
    -e "s|@STATUS_COMMAND@|$(escape_sed_replacement "$STATUS_COMMAND")|g" \
    -e "s|@START_COMMAND@|$(escape_sed_replacement "$START_COMMAND")|g" \
    "$TEMPLATE_DIR/monitor.sh.in" | tee "$MONITOR_SCRIPT" >/dev/null

chmod +x "$MONITOR_SCRIPT"

# Step 10: Create the restart script
echo "Creating the restart script..."
case "$OS" in
freebsd)
    LOG_COMMAND='logger -t minecraft-restart "$*"'
    RESTART_COMMAND='service minecraft restart'
    ;;
ubuntu)
    LOG_COMMAND='printf "%s\n" "$*" | systemd-cat -t minecraft-restart'
    RESTART_COMMAND='systemctl restart minecraft.service'
    ;;
esac

sed -e "s|@CONFIG_FILE@|$(escape_sed_replacement "$CONFIG_FILE")|g" \
    -e "s|@LOG_COMMAND@|$(escape_sed_replacement "$LOG_COMMAND")|g" \
    -e "s|@RESTART_COMMAND@|$(escape_sed_replacement "$RESTART_COMMAND")|g" \
    "$TEMPLATE_DIR/restart.sh.in" | tee "$RESTART_SCRIPT" >/dev/null

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
start_message
