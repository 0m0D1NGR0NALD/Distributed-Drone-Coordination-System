#!/usr/bin/env python3
# python_frontend/erlang_connector.py
"""
Simple socket-based Erlang connector
No external dependencies beyond standard library
"""
import socket
import threading
import time
import struct
import re
from typing import Dict, Any, Callable, List, Optional
import config


class SimpleErlangConnector:
    """
    Connects to Erlang using a simple TCP socket
    This requires a corresponding port program in Erlang
    """
    
    def __init__(self):
        self.connected = False
        self.socket = None
        self.receive_thread = None
        self.running = False
        self.drone_updates = []
        self.station_status = {}
        self.callbacks = []
        
    def connect(self, host=config.ERLANG_HOST, port=config.ERLANG_PORT) -> bool:
        """Connect to Erlang port"""
        try:
            print(f"🟢 Connecting to Erlang at {host}:{port}...")
            
            # Create socket
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.connect((host, port))
            
            # Start receive thread
            self.running = True
            self.receive_thread = threading.Thread(target=self._receive_loop, daemon=True)
            self.receive_thread.start()
            
            self.connected = True
            print(f"🟢 Connected to Erlang")
            return True
            
        except Exception as e:
            print(f"🔴 Failed to connect: {e}")
            return False
    
    def _receive_loop(self):
        """Receive messages from Erlang"""
        while self.running:
            try:
                # Read message length (4 bytes, network byte order)
                data = self.socket.recv(4)
                if not data or len(data) < 4:
                    break
                
                msg_len = struct.unpack('!I', data)[0]
                
                # Read message
                msg_data = b''
                while len(msg_data) < msg_len:
                    chunk = self.socket.recv(msg_len - len(msg_data))
                    if not chunk:
                        break
                    msg_data += chunk
                
                if msg_data:
                    # Try to decode as string
                    try:
                        msg_str = msg_data.decode('utf-8').strip()
                        print(f"Received string: {msg_str}")
                        self._process_message(msg_str)
                    except UnicodeDecodeError:
                        # If not a string, it might be binary data from term_to_binary
                        print(f"Received binary data: {len(msg_data)} bytes")
                        self._process_binary(msg_data)
                        
            except Exception as e:
                print(f"Error in receive loop: {e}")
                self.connected = False
                break
        
        self.connected = False
        print("🔴 Disconnected from Erlang")
    
    def _process_binary(self, data: bytes):
        """Process binary messages from Erlang"""
        try:
            # Try to decode as string first
            msg_str = data.decode('utf-8').strip()
            print(f"Received decoded: {msg_str}")
            
            # Parse CSV format: "drone_id,x,y,battery,status"
            parts = msg_str.split(',')
            if len(parts) >= 5:
                # Extract numeric part from first field (handles "k101" format)
                first_field = parts[0].strip()
                # Remove any non-digit characters from the beginning
                drone_id_match = re.search(r'\d+', first_field)
                
                if drone_id_match:
                    drone_id = int(drone_id_match.group())
                    try:
                        update = {
                            'drone_id': drone_id,
                            'x': float(parts[1]),
                            'y': float(parts[2]),
                            'battery': int(parts[3]),
                            'status': self._decode_status(parts[4]),
                            'timestamp': time.time()
                        }
                        self.drone_updates.append(update)
                        print(f"🟢 Drone {drone_id} added at ({update['x']:.1f}, {update['y']:.1f})")
                        if len(self.drone_updates) > 100:
                            self.drone_updates = self.drone_updates[-100:]
                    except (ValueError, IndexError) as e:
                        print(f"🔴 Error parsing telemetry: {e}, data: {msg_str}")
                else:
                    print(f"⚠️ No numeric drone ID found in: {first_field}")
        except UnicodeDecodeError:
            print(f"🔴 Failed to decode binary data: {data.hex()[:50]}...")
    
    def _process_message(self, message: str):
        """Process incoming string messages"""
        print(f"Received: {message}")
        
        # Simple CSV format: "drone_id,x,y,battery,status"
        parts = message.strip().split(',')
        
        # Drone update format
        if len(parts) >= 5:
            # Extract numeric part from first field (handles "k101" format)
            first_field = parts[0].strip()
            drone_id_match = re.search(r'\d+', first_field)
            
            if drone_id_match:
                drone_id = int(drone_id_match.group())
                try:
                    update = {
                        'drone_id': drone_id,
                        'x': float(parts[1]),
                        'y': float(parts[2]),
                        'battery': int(parts[3]),
                        'status': self._decode_status(parts[4]),
                        'timestamp': time.time()
                    }
                    self.drone_updates.append(update)
                    print(f"🟢 Drone {drone_id} at ({update['x']:.1f}, {update['y']:.1f}) bat:{update['battery']}%")
                    if len(self.drone_updates) > 100:
                        self.drone_updates = self.drone_updates[-100:]
                except ValueError as e:
                    print(f"🔴 Error parsing drone update: {e}, data: {message}")
            else:
                print(f"⚠️ No numeric drone ID in: {first_field}")
        
        # Station status format
        elif len(parts) >= 2 and parts[0] == 'STATUS':
            station = parts[1]
            drone_count = int(parts[2]) if len(parts) > 2 else 0
            is_leader = parts[3] if len(parts) > 3 else 'false'
            drone_ids = parts[4:] if len(parts) > 4 else []
            self.station_status[station] = {
                'name': station,
                'drone_count': drone_count,
                'timestamp': time.time(),
                'is_leader': is_leader,
                'drone_ids': drone_ids,
                'timestamp': time.time()
            }
        
        # Handoff notification
        elif len(parts) >= 3 and parts[0] == 'HANDOFF':
            drone_id = parts[1]
            from_station = parts[2]
            to_station = parts[3] if len(parts) > 3 else 'unknown'
            print(f"Drone {drone_id} handed off from {from_station} to {to_station}")
        
        # Call callbacks
        for callback in self.callbacks:
            try:
                callback(message)
            except Exception as e:
                print(f"Error in callback: {e}")
    
    def _decode_status(self, status: str) -> str:
        """Convert status code to emoji status"""
        status_map = {
            'idle': '🟢 Idle',
            'moving': '🔵 Moving',
            'returning': '🟡 Returning',
            'low_battery': '🟠 Low Battery',
            'emergency': '🔴 Emergency',
            'test': '⚠️ Test'
        }
        # Clean the status string
        status_clean = status.strip().lower()
        return status_map.get(status_clean, status)
    
    def send_command(self, command: str) -> bool:
        """Send command to Erlang"""
        try:
            # Format: "cmd,param1,param2,..."
            cmd_bytes = command.encode('utf-8')
            msg_len = struct.pack('!I', len(cmd_bytes))
            self.socket.send(msg_len + cmd_bytes)
            print(f"🟢 Sent: {command}")
            return True
        except Exception as e:
            print(f"🔴 Failed to send: {e} (socket connected: {self.connected})")
            self.disconnect()
            time.sleep(1)
            if self.connect():
                return self.send_command(command)  # retry once
            return False
    
    def launch_drone(self, station: str, drone_id: int) -> bool:
        """Launch a drone from a ground station"""
        return self.send_command(f"launch,{station},{drone_id}")
    
    def set_waypoint(self, station: str, drone_id: int, x: float, y: float) -> bool:
        """Set a waypoint for a drone"""
        return self.send_command(f"waypoint,{station},{drone_id},{x:.1f},{y:.1f}")
    
    def transfer_drone(self, station: str, drone_id: int, target: str) -> bool:
        """Transfer a drone to another ground station"""
        return self.send_command(f"transfer,{station},{drone_id},{target}")
    
    def request_status(self, station: str) -> bool:
        """Request status from a ground station"""
        return self.send_command(f"status,{station}")
    
    def get_drone_positions(self) -> List[Dict]:
        """Get latest drone positions"""
        # Return unique latest position for each drone
        latest = {}
        for update in reversed(self.drone_updates):
            drone_id = update['drone_id']
            if drone_id not in latest:
                latest[drone_id] = update
        return list(latest.values())
    
    def get_drone_history(self, drone_id: int, limit: int = 50) -> List[Dict]:
        """Get position history for a specific drone"""
        history = [u for u in self.drone_updates if u['drone_id'] == drone_id]
        return history[-limit:]
    
    def register_callback(self, callback: Callable):
        """Register callback for incoming messages"""
        self.callbacks.append(callback)
    
    def disconnect(self):
        """Disconnect from Erlang"""
        self.running = False
        if self.socket:
            try:
                self.socket.close()
            except:
                pass
        print("🔴 Disconnected from Erlang")
