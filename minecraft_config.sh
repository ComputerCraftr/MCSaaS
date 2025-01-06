#!/bin/sh

# Configuration variables for Minecraft server setup
export MINECRAFT_USER="minecraft"
export MINECRAFT_GROUP="minecraft"
export MINECRAFT_DIR="/var/minecraft_server"
export MINECRAFT_JAR="server.jar"
export SERVICE_SH="/usr/local/bin/minecraft_service.sh"
export MONITOR_SCRIPT="/usr/local/bin/minecraft_monitor.sh"
export RESTART_SCRIPT="/usr/local/bin/minecraft_restart.sh"
export PID_FILE="$MINECRAFT_DIR/minecraft_server.pid"
export MEMORY_ALLOCATION="8G"
export TMUX_SOCKET="minecraft_socket"
export TMUX_SESSION="minecraft_session"
