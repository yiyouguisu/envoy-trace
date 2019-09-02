#!/bin/sh
python /code/service.py &
envoy -l info -c /etc/service-envoy.yaml --service-cluster service${SERVICE_NAME}