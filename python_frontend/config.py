# python_frontend/config.py
"""
Configuration settings for the Drone Visualization System
"""

# Erlang connection settings
ERLANG_HOST = 'localhost'
ERLANG_PORT = 9000

# Ground stations in the cluster
GROUND_STATIONS = ['gs1', 'gs2']

# Web server settings
WEB_HOST = '0.0.0.0'
WEB_PORT = 5000
DEBUG_MODE = True

# Update intervals (seconds)
DRONE_UPDATE_INTERVAL = 0.5