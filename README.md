# Distributed-Drone-Coordination-System
The Distributed Drone Coordination System simulates multiple ground stations that manage drone fleets in a geographical area. The system demonstrates core distributed systems concepts including fault tolerance, leader election, and inter-node communication through an accessible drone coordination domain.


## Core Concepts

* Actor Model: Drones and ground stations as independent concurrent entities

* Fault Tolerance: Automatic recovery from node failures

* Leader Election: Democratic selection of cluster coordinators

* Dynamic Handoff: Seamless transfer of drones between stations

## System Architecture
<img width="1314" height="1266" alt="dsmt drawio" src="https://github.com/user-attachments/assets/ab63064b-2844-4aa0-be27-8505176c9cb2" />

## Key Features
### Distributed Operations
* Multiple ground stations running on different machines
* Real-time message passing between stations
* Automatic leader election on node failure
* State replication across cluster
  
### Drone Management
* Launch drones from any ground station
* Set waypoints via map interface
* Automatic handoff when crossing regional boundaries
* Real-time telemetry (position, battery, status)
  
### Interactive Frontend
* Live map with drone positions and trails
* Click-to-command waypoint setting
 Ground station status panels


