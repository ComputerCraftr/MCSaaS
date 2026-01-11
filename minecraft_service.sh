#!/bin/sh

# Exit on errors and undefined variables
set -eu

# Define the location of the config file
CONFIG_FILE="/etc/minecraftcfg"

# Source the configuration file
# shellcheck source=templates/config.sh.in
. "$CONFIG_FILE"

# Run commands as the Minecraft user; skip chpst when already running as that user.
if [ "$(id -u -n)" = "$MINECRAFT_USER" ]; then
    RUN_MINECRAFT_CMD() {
        "$@"
    }
else
    # Resolve chpst lazily so services running as root can drop privileges.
    if [ -z "${CHPST_PATH:-}" ]; then
        CHPST_PATH=$(command -v chpst)
    fi
    if [ -z "${CHPST_PATH:-}" ]; then
        echo "chpst is required but was not found in PATH." >&2
        exit 1
    fi
    RUN_MINECRAFT_CMD() {
        "$CHPST_PATH" -u "$MINECRAFT_USER" -- "$@"
    }
fi

try_perm() {
    if ! "$@"; then
        echo "Warning: permission update failed: $*" >&2
    fi
}

minecraft_start() {
    if [ ! -d "$MINECRAFT_DIR" ]; then
        echo "Minecraft server directory $MINECRAFT_DIR does not exist."
        return 1
    fi

    if ! session_running; then
        echo "Starting Minecraft server..."

        # Prepare the tmux socket for the new session
        mkdir -p "$TMUX_SOCKET_DIR"
        try_perm chown -R "$MINECRAFT_USER:$MINECRAFT_GROUP" "$TMUX_SOCKET_DIR"
        try_perm chmod -R u+rwX,g+rwX,o-rwx "$TMUX_SOCKET_DIR"
        try_perm chown -R "$MINECRAFT_USER:$MINECRAFT_GROUP" "$MINECRAFT_DIR"
        try_perm chmod -R u+rwX,g+rwX,o-rwx "$MINECRAFT_DIR"

        # Start the Minecraft server
        if [ "$RUNIT_WAIT" -eq 1 ]; then
            tmux_start_command="$START_COMMAND"
            # Strip any leading exec so that we can notify tmux later
            case "$tmux_start_command" in
            "exec "*)
                tmux_start_command=${tmux_start_command#exec }
                ;;
            esac
            tmux_start_command="$tmux_start_command; \"$TMUX_PATH\" -S \"$TMUX_SOCKET_PATH\" wait-for -S \"exit-$TMUX_SESSION\""
            RUN_MINECRAFT_CMD "$TMUX_PATH" -S "$TMUX_SOCKET_PATH" new-session -d -s "$TMUX_SESSION" -c "$MINECRAFT_DIR" /bin/sh -c "$tmux_start_command"
        else
            RUN_MINECRAFT_CMD "$TMUX_PATH" -S "$TMUX_SOCKET_PATH" new-session -d -s "$TMUX_SESSION" -c "$MINECRAFT_DIR" "$START_COMMAND"
        fi
        echo "Minecraft server started in detached tmux session '$TMUX_SESSION'."

        # Get the server PID
        pid=$(RUN_MINECRAFT_CMD "$TMUX_PATH" -S "$TMUX_SOCKET_PATH" list-panes -t "$TMUX_SESSION" -F '#{pane_pid}')
        if [ "$(echo "$pid" | wc -l)" -ne 1 ]; then
            echo "Failed to determine server PID, multiple active tmux sessions."
            return 1
        fi
        printf "%s" "$pid" >"$PID_PATH"

        # Allow group access to the tmux session
        for user in $(getent group "$MINECRAFT_GROUP" | cut -d ':' -f 4 | tr ',' '\n'); do
            if [ "$user" != "$MINECRAFT_USER" ] && [ -n "$user" ]; then
                RUN_MINECRAFT_CMD "$TMUX_PATH" -S "$TMUX_SOCKET_PATH" server-access -a "$user"
            fi
        done
        try_perm chown -R "$MINECRAFT_USER:$MINECRAFT_GROUP" "$TMUX_SOCKET_DIR"
        try_perm chmod -R u+rwX,g+rwX,o-rwx "$TMUX_SOCKET_DIR"

        # Wait for the tmux exit signal in order to allow process supervision
        if [ "$RUNIT_WAIT" -eq 1 ]; then
            runit_cleanup() {
                rc=$?
                if [ -n "${wait_pid:-}" ]; then
                    kill "$wait_pid" 2>/dev/null || true
                    wait "$wait_pid" 2>/dev/null || true
                fi
                minecraft_stop || rc=$?
                exit $rc
            }
            trap runit_cleanup INT TERM HUP
            RUN_MINECRAFT_CMD "$TMUX_PATH" -S "$TMUX_SOCKET_PATH" wait-for "exit-$TMUX_SESSION" &
            wait_pid=$!
            wait "$wait_pid"
        fi
    else
        echo "A tmux session named '$TMUX_SESSION' is already running."
        return 1
    fi
}

session_running() {
    RUN_MINECRAFT_CMD "$TMUX_PATH" -S "$TMUX_SOCKET_PATH" has-session -t "$TMUX_SESSION" 2>/dev/null
}

issue_cmd() {
    command="$*"
    RUN_MINECRAFT_CMD "$TMUX_PATH" -S "$TMUX_SOCKET_PATH" send-keys -t "$TMUX_SESSION.0" "$command" C-m
}

minecraft_stop() {
    if ! session_running; then
        echo "The server is already stopped."
        if [ -f "$PID_PATH" ]; then
            # Return any nonzero status of the rm command
            rm "$PID_PATH"
        fi
        # Return 0 if the PID file does not exist
        return 0
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
        # Return any nonzero status of the rm command
        rm "$PID_PATH"
    fi
}

minecraft_log() {
    if [ -f "$MINECRAFT_DIR/logs/latest.log" ]; then
        tail -f "$MINECRAFT_DIR/logs/latest.log"
    else
        echo "Log file does not exist."
        return 1
    fi
}

minecraft_attach() {
    if session_running; then
        RUN_MINECRAFT_CMD env TERM=screen-256color "$TMUX_PATH" -S "$TMUX_SOCKET_PATH" attach-session -t "$TMUX_SESSION.0" ||
            RUN_MINECRAFT_CMD env TERM=screen "$TMUX_PATH" -S "$TMUX_SOCKET_PATH" attach-session -t "$TMUX_SESSION.0"
    else
        echo "No tmux session named '$TMUX_SESSION' is running."
        return 1
    fi
}

minecraft_cmd() {
    if [ $# -eq 0 ]; then
        echo "No command provided. Usage: $0 cmd '<command>'"
        return 2
    fi

    command="$*"
    if session_running; then
        issue_cmd "$command"
        echo "Command '$command' sent to Minecraft server."
    else
        echo "No tmux session named '$TMUX_SESSION' is running."
        return 1
    fi
}

minecraft_reload() {
    if session_running; then
        issue_cmd "reload"
        echo "Reload command sent to Minecraft server."
    else
        echo "No tmux session named '$TMUX_SESSION' is running."
        return 1
    fi
}

minecraft_status() {
    if session_running; then
        echo "Minecraft server is running in tmux session '$TMUX_SESSION'."
    else
        echo "Minecraft server is not running."
    fi
}

RUNIT_WAIT=0
case "$1" in
--runit)
    shift
    case "$1" in
    start)
        RUNIT_WAIT=1
        minecraft_start
        ;;
    *)
        echo "Usage: $0 [--runit] start"
        exit 2
        ;;
    esac
    ;;
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
    echo "Usage: $0 [--runit] start | $0 {stop|log|attach|cmd|reload|status}"
    exit 2
    ;;
esac
