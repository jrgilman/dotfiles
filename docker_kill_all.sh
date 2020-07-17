#!/bin/bash

docker kill $(docker ps | tail -n +2 | sed 's/\(^[a-zA-Z0-9]\+\)\(.*\)/\1/' | sed ':a;N;$!ba;s/\n/ /g')
