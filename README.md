# difyonekeydeployment
Deploy dify in your linux with one script.

Tested with CentOS 8 and Ubuntu 22.04

# Deployment Architecture Overview

This solution uses Docker Compose to containerize Dify, with Nginx as a reverse proxy to handle domain access and SSL termination. The overall architecture includes the following components:

- Dify Stack: Four-container architecture including web, API, database, and Redis

- Nginx Service: Handles reverse proxy and SSL termination

- acme.sh: Automatically issues and renews Let's Encrypt certificates

# Environment Preparation Requirements
## System Requirements

- Operating System: Ubuntu 20.04+/Debian 11+/CentOS 8+

- Hardware: ≥ 2 CPU cores, ≥ 4GB RAM, ≥ 20GB SSD storage

- Network: Ports 80 and 443 open; domain name DNS resolution completed