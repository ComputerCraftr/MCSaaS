#!/bin/sh

# Exit on errors and undefined variables
set -eu

# Define the location of the config file
CONFIG_FILE="/etc/minecraft_config.sh"

# Source the configuration file
# shellcheck source=minecraft_config.sh
. "$CONFIG_FILE"

# Function to run a command as MINECRAFT_USER if the current user is not MINECRAFT_USER
run_as_minecraft_user() {
    if [ "$(id -u -n)" = "$MINECRAFT_USER" ]; then
        /bin/sh -c "$*"
    else
        if [ -z "${CHPST_PATH:-}" ]; then
            CHPST_PATH=$(command -v chpst)
        fi
        if [ -z "${CHPST_PATH:-}" ]; then
            echo "chpst is required but was not found in PATH." >&2
            return 1
        fi
        "$CHPST_PATH" -u "$MINECRAFT_USER" /bin/sh -c "$*"
    fi
}

minecraft_start() {
    if [ ! -d "$MINECRAFT_DIR" ]; then
        echo "Minecraft server directory $MINECRAFT_DIR does not exist."
        return 1
    fi

    if ! session_running; then
        echo "Starting Minecraft server..."
        mkdir -p "$TMUX_SOCKET_DIR"
        chown -R "$MINECRAFT_USER:$MINECRAFT_GROUP" "$TMUX_SOCKET_DIR"
        run_as_minecraft_user "$TMUX_PATH -S $TMUX_SOCKET_PATH new-session -d -s $TMUX_SESSION -c $MINECRAFT_DIR \"$START_COMMAND\""
        echo "Minecraft server started in detached tmux session '$TMUX_SESSION'."
        pid=$(run_as_minecraft_user "$TMUX_PATH -S $TMUX_SOCKET_PATH list-panes -t $TMUX_SESSION -F '#{pane_pid}'")
        if [ "$(echo "$pid" | wc -l)" -ne 1 ]; then
            echo "Failed to determine server PID, multiple active tmux sessions."
            return 1
        fi
        printf "%s" "$pid" >"$PID_PATH"
        for user in $(getent group "$MINECRAFT_GROUP" | cut -d ':' -f 4 | tr ',' '\n'); do
            if [ "$user" != "$MINECRAFT_USER" ] && [ -n "$user" ]; then
                run_as_minecraft_user "$TMUX_PATH -S $TMUX_SOCKET_PATH server-access -a \"$user\""
            fi
        done
        chown -R "$MINECRAFT_USER:$MINECRAFT_GROUP" "$TMUX_SOCKET_DIR"
        chmod 660 "$TMUX_SOCKET_PATH"
        chmod 770 "$TMUX_SOCKET_DIR"
    else
        echo "A tmux session named '$TMUX_SESSION' is already running."
    fi
}

session_running() {
    run_as_minecraft_user "$TMUX_PATH -S $TMUX_SOCKET_PATH has-session -t $TMUX_SESSION" 2>/dev/null
}

issue_cmd() {
    command="$*"
    run_as_minecraft_user "$TMUX_PATH -S $TMUX_SOCKET_PATH send-keys -t $TMUX_SESSION.0 \"$command\" C-m"
}

minecraft_stop() {
    if ! session_running; then
        echo "The server is already stopped."
        if [ -f "$PID_PATH" ]; then
            rm "$PID_PATH"
            return $? # Return the status of the rm command
        else
            return 0 # Return 0 if the PID file does not exist
        fi
    fi

    # Warn players with a 20-second countdown
    echo "Warning players..."
    for i in $(seq 20 -1 1); do
        issue_cmd "say Shutting down in $i second(s)"
        if [ $((i % 5)) -eq 0 ]; then
            echo "$i seconds remaining..."
        fi
        sleep 1
    done

    # Issue the stop command
    echo "Stopping server..."
    if ! issue_cmd "stop"; then
        echo "Failed to send stop command to server."
        return 1
    fi

    # Wait for the server to stop
    echo "Waiting for server to stop..."
    wait=0
    while session_running; do
        sleep 1
        wait=$((wait + 1))
        if [ $wait -gt 60 ]; then
            echo "Timed out waiting for server to stop."
            return 1
        fi
    done

    echo "Server stopped successfully."
    if [ -f "$PID_PATH" ]; then
        rm "$PID_PATH"
        return $? # Return the status of the rm command
    else
        return 0 # Return 0 if the PID file does not exist
    fi
}

minecraft_log() {
    if [ -f "$MINECRAFT_DIR/logs/latest.log" ]; then
        tail -f "$MINECRAFT_DIR/logs/latest.log"
    else
        echo "Log file does not exist."
    fi
}

minecraft_attach() {
    if session_running; then
        run_as_minecraft_user "TERM=screen-256color $TMUX_PATH -S $TMUX_SOCKET_PATH attach-session -t $TMUX_SESSION.0" ||
            run_as_minecraft_user "TERM=screen $TMUX_PATH -S $TMUX_SOCKET_PATH attach-session -t $TMUX_SESSION.0"
    else
        echo "No tmux session named '$TMUX_SESSION' is running."
    fi
}

minecraft_cmd() {
    if [ $# -eq 0 ]; then
        echo "No command provided. Usage: $0 cmd '<command>'"
        return 1
    fi

    command="$*"
    if session_running; then
        issue_cmd "$command"
        echo "Command '$command' sent to Minecraft server."
    else
        echo "No tmux session named '$TMUX_SESSION' is running."
    fi
}

minecraft_reload() {
    if session_running; then
        issue_cmd "reload"
        echo "Reload command sent to Minecraft server."
    else
        echo "No tmux session named '$TMUX_SESSION' is running."
    fi
}

minecraft_status() {
    if session_running; then
        echo "Minecraft server is running in tmux session '$TMUX_SESSION'."
    else
        echo "Minecraft server is not running."
    fi
}

case "$1" in
start)
    minecraft_start
    ;;
stop)
    minecraft_stop
    ;;
log)
    minecraft_log
    ;;
attach)
    minecraft_attach
    ;;
cmd)
    shift
    minecraft_cmd "$@"
    ;;
reload)
    minecraft_reload
    ;;
status)
    minecraft_status
    ;;
*)
    echo "Usage: $0 {start|stop|log|attach|cmd|reload|status}"
    exit 2
    ;;
esac
