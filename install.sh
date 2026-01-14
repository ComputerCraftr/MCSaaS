#!/bin/sh
# install.sh – Installer for Minecraft server on Ubuntu/Debian/FreeBSD/Void Linux

# Exit on errors and undefined variables
set -eu

usage() {
    echo "Usage: $0 --os {Ubuntu|Debian|FreeBSD|Void} [--runit] [--nodl]"
    echo "  --os        Target OS (Ubuntu, Debian, FreeBSD, or Void)"
    echo "  --runit     Use runit instead of the default init system"
    echo "  --url URL   Download URL for the Minecraft server jar"
    echo "  --nodl      Skip downloading the Minecraft server jar"
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
USE_RUNIT=0
while [ $# -gt 0 ]; do
    case "$1" in
    --os)
        OS="$2"
        shift 2
        ;;
    --runit)
        USE_RUNIT=1
        shift
        ;;
    --url)
        DOWNLOAD_URL="$2"
        shift 2
        ;;
    --nodl)
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
        exit 2
        ;;
    esac
done

if [ -z "$OS" ]; then
    echo "Missing required --os flag."
    usage
    exit 2
fi

OS_INPUT="$OS"
OS=$(printf '%s' "$OS" | tr '[:upper:]' '[:lower:]')

if [ "$OS" = "ubuntu" ]; then
    OS="debian"
fi

if [ "$DOWNLOAD" -eq 0 ] && [ -n "$DOWNLOAD_URL" ]; then
    echo "Cannot use --url with --nodl."
    usage
    exit 2
fi

case "$OS" in
debian | freebsd | void) ;;
*)
    echo "Unsupported OS: $OS_INPUT"
    usage
    exit 2
    ;;
esac

# Define the location of the config file
CONFIG_FILE="/etc/minecraftcfg"
RUNIT_SERVICE_DIR="/etc/sv/minecraft"

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
    debian | void) groupadd "$name" ;;
    freebsd) pw groupadd -n "$name" ;;
    esac
}

add_user() {
    name="$1"
    case "$OS" in
    debian)
        adduser --ingroup "$MINECRAFT_GROUP" --home "$MINECRAFT_DIR" --system --disabled-login --shell /bin/sh --comment "Minecraft Server User" "$name"
        ;;
    freebsd)
        pw useradd -g "$MINECRAFT_GROUP" -d "$MINECRAFT_DIR" -m -w no -s /bin/sh -c "Minecraft Server User" -n "$name"
        ;;
    void)
        useradd -g "$MINECRAFT_GROUP" -d "$MINECRAFT_DIR" -m -r -s /bin/sh -c "Minecraft Server User" "$name"
        ;;
    esac
}

add_user_to_group() {
    user="$1"
    group="$2"
    case "$OS" in
    debian | void) usermod -aG "$group" "$user" ;;
    freebsd) pw groupmod -n "$group" -m "$user" ;;
    esac
}

install_packages() {
    case "$OS" in
    debian)
        apt update
        apt install -y tmux curl runit openjdk-17-jre-headless
        ;;
    freebsd)
        pkg update
        pkg install -y tmux curl runit openjdk17-jre
        ;;
    void)
        xbps-install -Suy tmux curl runit openjdk17-jre
        ;;
    esac
}

enable_service() {
    if [ -d /etc/service ]; then
        RUNIT_SERVICE_LINK_DIR="/etc/service"
    else
        RUNIT_SERVICE_LINK_DIR="/var/service"
    fi

    if [ "$USE_RUNIT" -eq 1 ]; then
        mkdir -p "$RUNIT_SERVICE_LINK_DIR"
        ln -sf "$RUNIT_SERVICE_DIR" "$RUNIT_SERVICE_LINK_DIR"
        return
    fi

    case "$OS" in
    debian)
        systemctl daemon-reload
        systemctl enable minecraft.service
        ;;
    freebsd)
        sysrc minecraft_enable="YES"
        ;;
    void)
        mkdir -p "$RUNIT_SERVICE_LINK_DIR"
        ln -sf "$RUNIT_SERVICE_DIR" "$RUNIT_SERVICE_LINK_DIR"
        ;;
    esac
}

start_message() {
    START_MESSAGE_PREFIX="You can start the Minecraft server with: "

    if [ "$USE_RUNIT" -eq 1 ]; then
        echo "${START_MESSAGE_PREFIX}sudo sv up minecraft"
        return
    fi

    case "$OS" in
    debian) echo "${START_MESSAGE_PREFIX}sudo systemctl start minecraft.service" ;;
    freebsd) echo "${START_MESSAGE_PREFIX}sudo service minecraft start" ;;
    void) echo "${START_MESSAGE_PREFIX}sudo sv up minecraft" ;;
    esac
}

# Step 1: Install necessary packages
echo "Installing necessary packages..."
install_packages

# Verify required commands are available
required_cmds="tmux java curl chpst"
if [ "$USE_RUNIT" -eq 1 ] || [ "$OS" = "void" ]; then
    required_cmds="$required_cmds sv logger"
fi

for cmd in $required_cmds; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "$cmd is required but not installed. Exiting."
        exit 1
    }
done

# Step 2: Render the configuration file (idempotent)
echo "Rendering the configuration file..."
temp_config=$(mktemp)

CONFIG_OWNER="root:$(id -gn 0)"
RESOURCE_LIMIT_LINE=''
# shellcheck disable=SC2016
START_COMMAND_LINE='START_COMMAND="$MINECRAFT_COMMAND"'
if [ "$USE_RUNIT" -eq 1 ]; then
    SERVICE_LINE="RUNIT_SERVICE_DIR=\"$RUNIT_SERVICE_DIR\""
    case "$OS" in
    freebsd)
        RESOURCE_LIMIT_LINE='RESOURCE_LIMIT_COMMAND="ulimit -u 256"'
        # shellcheck disable=SC2016
        START_COMMAND_LINE='START_COMMAND="$RESOURCE_LIMIT_COMMAND && $MINECRAFT_COMMAND"'
        ;;
    esac
else
    case "$OS" in
    debian)
        SERVICE_LINE='SERVICE_UNIT="/etc/systemd/system/minecraft.service"'
        ;;
    freebsd)
        SERVICE_LINE='RC_SCRIPT="/usr/local/etc/rc.d/minecraft"'
        RESOURCE_LIMIT_LINE='RESOURCE_LIMIT_COMMAND="ulimit -u 256"'
        # shellcheck disable=SC2016
        START_COMMAND_LINE='START_COMMAND="$RESOURCE_LIMIT_COMMAND && $MINECRAFT_COMMAND"'
        ;;
    void)
        SERVICE_LINE="RUNIT_SERVICE_DIR=\"$RUNIT_SERVICE_DIR\""
        ;;
    esac
fi

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
chown -R "$MINECRAFT_USER:$MINECRAFT_GROUP" "$MINECRAFT_DIR"
chmod -R u+rwX,g+rwX,o-rwx "$MINECRAFT_DIR"

# Step 4: Download Minecraft server jar if not in --nodl mode
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
    echo "Skipping download of Minecraft server jar due to --nodl option."
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

if [ "$USE_RUNIT" -eq 1 ]; then
    mkdir -p "$RUNIT_SERVICE_DIR"
    sed -e "s|@SERVICE_SCRIPT@|$ESC_SERVICE_SCRIPT|g" \
        "$TEMPLATE_DIR/runit.run.in" >"$RUNIT_SERVICE_DIR/run"
    chmod +x "$RUNIT_SERVICE_DIR/run"
else
    case "$OS" in
    debian)
        sed -e "s|@MINECRAFT_USER@|$ESC_MINECRAFT_USER|g" \
            -e "s|@MINECRAFT_GROUP@|$ESC_MINECRAFT_GROUP|g" \
            -e "s|@MINECRAFT_DIR@|$ESC_MINECRAFT_DIR|g" \
            -e "s|@MEMORY_ALLOCATION@|$ESC_MEMORY_ALLOCATION|g" \
            -e "s|@PID_PATH@|$ESC_PID_PATH|g" \
            -e "s|@SERVICE_SCRIPT@|$ESC_SERVICE_SCRIPT|g" \
            "$TEMPLATE_DIR/minecraft.service.in" >"$SERVICE_UNIT"
        ;;
    freebsd)
        sed -e "s|@MINECRAFT_USER@|$ESC_MINECRAFT_USER|g" \
            -e "s|@MINECRAFT_GROUP@|$ESC_MINECRAFT_GROUP|g" \
            -e "s|@MINECRAFT_DIR@|$ESC_MINECRAFT_DIR|g" \
            -e "s|@SERVICE_SCRIPT@|$ESC_SERVICE_SCRIPT|g" \
            "$TEMPLATE_DIR/rc.d.in" >"$RC_SCRIPT"
        chmod +x "$RC_SCRIPT"
        ;;
    void)
        mkdir -p "$RUNIT_SERVICE_DIR"
        sed -e "s|@SERVICE_SCRIPT@|$ESC_SERVICE_SCRIPT|g" \
            "$TEMPLATE_DIR/runit.run.in" >"$RUNIT_SERVICE_DIR/run"
        chmod +x "$RUNIT_SERVICE_DIR/run"
        ;;
    esac
fi

# Step 8: Enable the service
echo "Enabling the Minecraft service..."
enable_service

# Step 9: Create the monitoring script
echo "Creating the monitoring script..."

LOG_COMMAND='logger -t minecraft-monitor "$*"'
if [ "$USE_RUNIT" -eq 1 ]; then
    STATUS_COMMAND='sv status minecraft | grep -q "^run:"'
    START_COMMAND='sv up minecraft'
else
    case "$OS" in
    debian)
        LOG_COMMAND='printf "%s\n" "$*" | systemd-cat -t minecraft-monitor'
        STATUS_COMMAND='systemctl is-active --quiet minecraft.service'
        START_COMMAND='systemctl start minecraft.service'
        ;;
    freebsd)
        STATUS_COMMAND='service minecraft status | grep -qF "Minecraft server is running"'
        START_COMMAND='service minecraft start'
        ;;
    void)
        STATUS_COMMAND='sv status minecraft | grep -q "^run:"'
        START_COMMAND='sv up minecraft'
        ;;
    esac
fi

sed -e "s|@LOG_COMMAND@|$(escape_sed_replacement "$LOG_COMMAND")|g" \
    -e "s|@STATUS_COMMAND@|$(escape_sed_replacement "$STATUS_COMMAND")|g" \
    -e "s|@START_COMMAND@|$(escape_sed_replacement "$START_COMMAND")|g" \
    "$TEMPLATE_DIR/monitor.sh.in" >"$MONITOR_SCRIPT"

chmod +x "$MONITOR_SCRIPT"

# Step 10: Create the restart script
echo "Creating the restart script..."

LOG_COMMAND='logger -t minecraft-restart "$*"'
if [ "$USE_RUNIT" -eq 1 ]; then
    RESTART_COMMAND='sv restart minecraft'
else
    case "$OS" in
    debian)
        LOG_COMMAND='printf "%s\n" "$*" | systemd-cat -t minecraft-restart'
        RESTART_COMMAND='systemctl restart minecraft.service'
        ;;
    freebsd)
        RESTART_COMMAND='service minecraft restart'
        ;;
    void)
        RESTART_COMMAND='sv restart minecraft'
        ;;
    esac
fi

sed -e "s|@LOG_COMMAND@|$(escape_sed_replacement "$LOG_COMMAND")|g" \
    -e "s|@RESTART_COMMAND@|$(escape_sed_replacement "$RESTART_COMMAND")|g" \
    "$TEMPLATE_DIR/restart.sh.in" >"$RESTART_SCRIPT"

chmod +x "$RESTART_SCRIPT"

# Step 11: Set up cron jobs without creating duplicates
echo "Setting up cron jobs..."
current_crontab=$(crontab -l 2>/dev/null || true)

monitor_cron="*/30 * * * * $MONITOR_SCRIPT"
restart_cron="0 4 * * * $RESTART_SCRIPT"

temp_crontab=$(mktemp)

# Copy existing crontab to temp file
echo "$current_crontab" >"$temp_crontab"

cron_entries=""
if [ "$USE_RUNIT" -eq 1 ] || [ "$OS" = "void" ]; then
    cron_entries="$RESTART_SCRIPT|$restart_cron"
else
    cron_entries="$MONITOR_SCRIPT|$monitor_cron
$RESTART_SCRIPT|$restart_cron"
fi

printf "%s\n" "$cron_entries" | while IFS= read -r cron_entry; do
    [ -z "$cron_entry" ] && continue
    script_path=${cron_entry%%|*}
    cron_line=${cron_entry#*|}
    if ! grep -qF "$script_path" "$temp_crontab"; then
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
