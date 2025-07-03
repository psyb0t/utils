#!/usr/bin/env bash
nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,power.draw,power.limit,memory.used,memory.total \
  --format=csv,noheader,nounits | awk -F', *' '{ \
    print $1; \
    printf "%g%% %g°C %gW/%gW %gMiB/%gMiB\n", $2, $3, $4, $5, $6, $7; \
  }'
