#!/usr/bin/env python3
# python_frontend/web_server.py
"""
Flask web server with SocketIO for real-time drone visualization
"""
import time
import json
import threading
import eventlet
eventlet.monkey_patch()  # Must be called before importing other modules

from flask import Flask, render_template, jsonify, request
from flask_socketio import SocketIO, emit
import config

# Create the Flask app first
app = Flask(__name__)
app.config['SECRET_KEY'] = 'drone-secret-key'

# Initialize SocketIO with explicit async mode and CORS
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')
print(f"SocketIO async_mode: {socketio.async_mode}")  # Should print 'eventlet'

# Global state
drone_positions = {}
drone_history = {}
station_status = {}
connector = None

class WebServer:
    def __init__(self, erlang_connector):
        global connector
        connector = erlang_connector
        self.running = False
        self.update_thread = None
        
    def start(self, host=config.WEB_HOST, port=config.WEB_PORT):
        """Start the web server"""
        self.running = True
        
        # Start update broadcaster
        self.update_thread = threading.Thread(target=self._broadcast_updates, daemon=True)
        self.update_thread.start()
        
        print(f"\n🌐 Web server started at http://localhost:{port}")
        print("Visualize your drones in real-time!")
        print("Press Ctrl+C to stop\n")
        
        # Run Flask with SocketIO – disable reloader to avoid forking issues
        socketio.run(app, host=host, port=port, debug=config.DEBUG_MODE, use_reloader=False)
    
    def _broadcast_updates(self):
        """Broadcast drone positions to all connected clients"""
        global drone_positions, drone_history
        
        while self.running:
            try:
                if connector and connector.connected:
                    # Get latest drone positions
                    updates = connector.get_drone_positions()
                    
                    if updates:  # Only broadcast if there are updates
                        print(f"Broadcasting {len(updates)} drones to clients")
                        
                        for update in updates:
                            drone_id = update['drone_id']
                            drone_positions[drone_id] = update
                            
                            # Maintain history for trails
                            if drone_id not in drone_history:
                                drone_history[drone_id] = []
                            drone_history[drone_id].append({
                                'x': update['x'],
                                'y': update['y'],
                                't': update['timestamp']
                            })
                            # Keep last 50 positions for trail
                            if len(drone_history[drone_id]) > 50:
                                drone_history[drone_id] = drone_history[drone_id][-50:]
                        
                        # Broadcast to all connected clients via SocketIO
                        socketio.emit('drone_updates', {
                            'positions': list(drone_positions.values()),
                            'history': drone_history,
                            'stations': station_status 
                        })
                
                time.sleep(config.DRONE_UPDATE_INTERVAL)
            except Exception as e:
                print(f"🔴 Broadcast error: {e}")
                time.sleep(1)


# Flask Routes
@app.route('/')
def index():
    """Main page"""
    return render_template('index.html')

@app.route('/api/drones')
def api_drones():
    """API endpoint for drone positions"""
    return jsonify(list(drone_positions.values()))

@app.route('/api/stations')
def api_stations():
    """API endpoint for station status"""
    return jsonify(station_status)

@app.route('/api/drone/<int:drone_id>/history')
def api_drone_history(drone_id):
    """API endpoint for drone history"""
    history = drone_history.get(drone_id, [])
    return jsonify(history)

# SocketIO Events
@socketio.on('connect')
def handle_connect():
    """Handle client connection"""
    print(f'🟢 Client connected: {request.sid}')
    emit('connected', {
        'status': 'connected',
        'message': 'Connected to drone server',
        'stations': config.GROUND_STATIONS
    })

@socketio.on('disconnect')
def handle_disconnect():
    """Handle client disconnection"""
    print(f'🔴 Client disconnected: {request.sid}')

@socketio.on('command')
def handle_command(data):
    """Handle commands from web interface"""
    print(f"Received command: {data}")
    
    if not connector or not connector.connected:
        emit('command_ack', {'status': 'error', 'message': 'Not connected to Erlang'})
        return
    
    cmd_type = data.get('type')
    station = data.get('station', 'gs1')
    drone_id = data.get('drone_id')
    
    if cmd_type == 'launch_drone':
        success = connector.launch_drone(station, drone_id)
        emit('command_ack', {
            'status': 'success' if success else 'error',
            'command': cmd_type,
            'drone_id': drone_id
        })
        
    elif cmd_type == 'set_waypoint':
        x = data.get('x', 0)
        y = data.get('y', 0)
        success = connector.set_waypoint(station, drone_id, x, y)
        emit('command_ack', {
            'status': 'success' if success else 'error',
            'command': cmd_type,
            'drone_id': drone_id,
            'waypoint': {'x': x, 'y': y}
        })
        
    elif cmd_type == 'transfer_drone':
        target = data.get('target')
        success = connector.transfer_drone(station, drone_id, target)
        emit('command_ack', {
            'status': 'success' if success else 'error',
            'command': cmd_type,
            'drone_id': drone_id,
            'target': target
        })
        
    elif cmd_type == 'get_status':
        success = connector.request_status(station)
        emit('command_ack', {
            'status': 'success' if success else 'error',
            'command': cmd_type,
            'station': station
        })