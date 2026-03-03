#!/usr/bin/env python3
# python_frontend/main.py
"""
Main entry point for the Python Drone Visualization Frontend
"""
import sys
import time
from erlang_connector import SimpleErlangConnector
from web_server import WebServer
import config

def print_banner():
    """Print startup banner"""
    banner = """
    DISTRIBUTED DRONE COORDINATION SYSTEM
    """
    print(banner)
    print(f"Erlang Connection: {config.ERLANG_HOST}:{config.ERLANG_PORT}")
    print(f"Ground Stations: {', '.join(config.GROUND_STATIONS)}")

def main():
    """Main entry point"""
    print_banner()
    
    # Create connector
    connector = SimpleErlangConnector()
    
    # Connect to Erlang
    print("\nConnecting to Erlang...")
    if not connector.connect():
        print("🔴 Failed to connect to Erlang.")
        print("   Make sure the Erlang port program is running on port 9000")
        print("   Run: erl -sname port -setcookie drone_cookie -s drone_port start")
        sys.exit(1)
    
    # Start web server
    server = WebServer(connector)
    
    try:
        server.start()
    except KeyboardInterrupt:
        print("\n\n🔴 Shutting down...")
    finally:
        connector.disconnect()
        print("Arrivederci!")

if __name__ == '__main__':
    main()