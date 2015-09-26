#!/bin/sh

sudo systemctl stop redis-server.service
sudo cp /var/lib/redis/initial.rdb /var/lib/redis/dump.rdb
sudo systemctl start redis-server.service
