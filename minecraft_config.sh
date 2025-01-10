#!/bin/sh

# Exit on errors and undefined variables
set -eu

# Configuration variables for Minecraft server setup
export MINECRAFT_USER="minecraft"
export MINECRAFT_GROUP="minecraft"
export MINECRAFT_DIR="/var/minecraft_server"
export MINECRAFT_JAR="server.jar"
export SERVICE_SH="/usr/local/bin/minecraft_service.sh"
export MONITOR_SCRIPT="/usr/local/bin/minecraft_monitor.sh"
export RESTART_SCRIPT="/usr/local/bin/minecraft_restart.sh"
export PID_FILE="minecraft_server.pid"
export PID_PATH="${MINECRAFT_DIR}/${PID_FILE}"
export MEMORY_ALLOCATION="8G"
export TMUX_SOCKET_FILE="minecraft_socket"
export TMUX_SOCKET_DIR="/tmp/tmux-${MINECRAFT_USER}"
export TMUX_SOCKET_PATH="${TMUX_SOCKET_DIR}/${TMUX_SOCKET_FILE}"
export TMUX_SESSION="minecraft_session"
