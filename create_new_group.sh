SECRET=$(sudo cat /var/lib/husarnet/daemon_api_token)
JSON_PAYLOAD=$(jq -n -c --arg name "kalman_lab" --arg comment "grupo para sesisones de kalman lab" '$ARGS.named')
curl -s -H"X-Husarnet-Secret: $SECRET" -H"Content-Type: application/json" -d "$JSON_PAYLOAD" localhost:16216/api/forward/v3/web/groups