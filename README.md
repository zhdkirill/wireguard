# Wireguard
Simple wireguard client  
[Docker hub](https://hub.docker.com/r/zhdkirill/wireguard)

## Usage
- Wireguard starts with a configuration file wg0.conf placed under /etc/wireguard. Mount your configuration there.
- The image uses default wireguard-tools and `wg-quick up` command to set up the connection.
- The image requires `net_admin` cap.

### Sample compose file
```
services:
  wireguard:
    container_name: wireguard
    image: ghcr.io/zhdkirill/wireguard:latest
    cap_add:
      - net_admin
    volumes:
      - /path/to/your/wg.conf:/etc/wireguard/wg0.conf:ro
    restart: unless-stopped
```
