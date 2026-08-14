#!/bin/bash
docker pull  portainer/portainer-ce
docker-compose up -d --force-recreate
