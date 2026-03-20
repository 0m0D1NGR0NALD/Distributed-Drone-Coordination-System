// python_frontend/static/js/map.js
// Version with yellow station dots, no boundary label in legend

console.log("map.js loaded");

// ---------- Coordinate transformation ----------
function toGeo(ix, iy) {
    const baseLat = 0.3476;      // Kampala latitude
    const baseLon = 32.5825;     // Kampala longitude
    const scaleLat = 0.4155;      // (41.9028 - 0.3476) / 100
    const scaleLon = -0.2008;     // (12.4964 - 32.5825) / 100
    return {
        lat: baseLat + iy * scaleLat,
        lon: baseLon + ix * scaleLon
    };
}

function fromGeo(lat, lon) {
    const baseLat = 0.3476;
    const baseLon = 32.5825;
    const scaleLat = 0.4155;
    const scaleLon = -0.2008;
    return {
        x: (lon - baseLon) / scaleLon,
        y: (lat - baseLat) / scaleLat
    };
}

// ---------- Map setup ----------
const mapElement = document.getElementById('map');
if (!mapElement) console.error("🔴 Map element not found");
else console.log("🟢 Map container found");

const map = L.map('map');
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '© OpenStreetMap'
}).addTo(map);

// ---------- Socket.IO ----------
const socket = io({ transports: ['polling'] });

socket.on('connect', () => {
    document.getElementById('connection-status').className = 'connection-status connected';
    document.getElementById('connection-status').textContent = 'Connected';
});
socket.on('disconnect', () => {
    document.getElementById('connection-status').className = 'connection-status disconnected';
    document.getElementById('connection-status').textContent = 'Disconnected';
});

// ---------- Station markers (uniform yellow dots) ----------
const stationStyle = {
    radius: 6,
    fillColor: '#ffc107',   // yellow
    color: '#fff',
    weight: 2,
    opacity: 1,
    fillOpacity: 1
};

// Kampala (GS1)
const kampalaGeo = toGeo(0, 0);
const kampalaMarker = L.circleMarker([kampalaGeo.lat, kampalaGeo.lon], stationStyle)
    .addTo(map);
kampalaMarker.bindPopup('Kampala');

// Rome (GS2)
const romeGeo = toGeo(100, 100);
const romeMarker = L.circleMarker([romeGeo.lat, romeGeo.lon], stationStyle)
    .addTo(map);
romeMarker.bindPopup('Rome');

// ---------- Region circles (colored by station) ----------
const handoffRadius = 90 * 35.36 * 1000; // 90 internal units → meters

// Kampala region – red
L.circle([kampalaGeo.lat, kampalaGeo.lon], {
    color: '#e94560',
    weight: 2,
    opacity: 0.6,
    fillOpacity: 0.1,
    radius: handoffRadius
}).addTo(map);

// Rome region – blue
L.circle([romeGeo.lat, romeGeo.lon], {
    color: '#0f3460',
    weight: 2,
    opacity: 0.6,
    fillOpacity: 0.1,
    radius: handoffRadius
}).addTo(map);

// Zoom to fit both stations
map.fitBounds(L.latLngBounds([
    [kampalaGeo.lat, kampalaGeo.lon],
    [romeGeo.lat, romeGeo.lon]
]), { padding: [50, 50] });

// ---------- Drone markers storage ----------
const drones = {};
const trails = {};

// Determine drone color based on ID (1-199 = Kampala, 200+ = Rome)
function droneColor(id) {
    return id < 200 ? '#e94560' : '#0f3460';
}

// Update drone markers
socket.on('drone_updates', (data) => {
    document.getElementById('stat-drones').textContent = data.positions.length;
    updateDrones(data.positions);
    if (data.history) updateTrails(data.history);
    if (data.stations) updateStations(data.stations);
});

// Update stations
function updateStations(stationsData) {
    console.log('Updating stations:', stationsData);
    const container = document.getElementById('stations-container');
    if (!container) return;

    let html = '';
    for (const [name, data] of Object.entries(stationsData)) {
        const stationName = name === 'gs1' ? 'Kampala' : 'Rome';
        const droneCount = data.drone_count || 0;
        const droneIds = data.drone_ids || [];

        html += `
            <div class="station-card">
                <div class="station-header">
                    <span class="station-name">${stationName} (${name})</span>
                    <span class="station-badge">${droneCount} drones</span>
                </div>
                <div class="station-drones">
        `;

        if (droneIds.length === 0) {
            html += '<div class="drone-item">No drones</div>';
        } else {
            droneIds.forEach(id => {
                html += `
                    <div class="drone-item">
                        <span class="drone-id">Drone ${id}</span>
                    </div>
                `;
            });
        }

        html += `</div></div>`;
    }
    container.innerHTML = html;
}

function updateDrones(positions) {
    const activeIds = positions.map(p => p.drone_id);
    // Remove stale drones
    Object.keys(drones).forEach(id => {
        if (!activeIds.includes(parseInt(id))) {
            map.removeLayer(drones[id]);
            delete drones[id];
        }
    });
    // Add/update drones
    positions.forEach(pos => {
        const id = pos.drone_id;
        const geo = toGeo(pos.x, pos.y);
        const latlng = [geo.lat, geo.lon];
        if (drones[id]) {
            drones[id].setLatLng(latlng);
            drones[id].setStyle({ color: droneColor(id) });
            drones[id].getPopup().setContent(`
                <b>Drone ${id}</b><br>
                Battery: ${pos.battery}%<br>
                Status: ${pos.status}<br>
                Position: (${geo.lat.toFixed(4)}, ${geo.lon.toFixed(4)})
            `);
        } else {
            const marker = L.circleMarker(latlng, {
                radius: 5,
                color: droneColor(id),
                fillColor: droneColor(id),
                fillOpacity: 0.8,
                weight: 2
            }).addTo(map);
            marker.bindPopup(`
                <b>Drone ${id}</b><br>
                Battery: ${pos.battery}%<br>
                Status: ${pos.status}<br>
                Position: (${geo.lat.toFixed(4)}, ${geo.lon.toFixed(4)})
            `);
            drones[id] = marker;
        }
    });
}

function updateTrails(history) {
    Object.values(trails).forEach(t => map.removeLayer(t));
    Object.keys(history).forEach(id => {
        const points = history[id].map(p => {
            const geo = toGeo(p.x, p.y);
            return [geo.lat, geo.lon];
        });
        if (points.length > 1) {
            trails[id] = L.polyline(points, {
                color: droneColor(parseInt(id)),
                weight: 2,
                opacity: 0.6,
                dashArray: '5,5'
            }).addTo(map);
        }
    });
}

// ---------- Click-to-set-waypoint ----------
map.on('click', (e) => {
    const coords = e.latlng;
    document.getElementById('click-coords').innerHTML = `Selected: (${coords.lat.toFixed(4)}, ${coords.lng.toFixed(4)})`;
    const droneId = document.getElementById('drone-id')?.value;
    const station = document.getElementById('station-select')?.value;
    if (!droneId || !station) return;
    const internal = fromGeo(coords.lat, coords.lng);
    if (confirm(`Set waypoint for drone ${droneId} at (${coords.lat.toFixed(4)}, ${coords.lng.toFixed(4)})?`)) {
        socket.emit('command', {
            type: 'set_waypoint',
            station: station,
            drone_id: parseInt(droneId),
            x: internal.x,
            y: internal.y
        });
    }
});

// ---------- Command functions ----------
function launchDrone() {
    const station = document.getElementById('station-select').value;
    const droneId = document.getElementById('drone-id').value;
    socket.emit('command', { type: 'launch_drone', station, drone_id: parseInt(droneId) });
}

function transferDrone() {
    const station = document.getElementById('station-select').value;
    const droneId = document.getElementById('drone-id').value;
    const target = document.getElementById('target-station').value;
    socket.emit('command', { type: 'transfer_drone', station, drone_id: parseInt(droneId), target });
}

function refreshStatus() {
    const station = document.getElementById('station-select').value;
    socket.emit('command', { type: 'get_status', station });
}

console.log("🟢 map.js ready");