#!/bin/bash
# Free a port by killing the process using it
# Usage: ./free_port.sh <port_number>

free_port() {
  local port=$1
  if [ -z "$port" ]; then
    echo "No port provided. Please provide a port as an argument."
    exit 1
  fi
  pid=$(lsof -ti tcp:$port)
  if [ -n "$pid" ]; then
    echo "Port $port is in use by process $pid. Killing it..."
    kill -9 $pid
    echo "Port $port has been released."
  else
    echo "Port $port is already free."
  fi
}

# Command dispatcher
free_port "$1"