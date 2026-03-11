# Primero obtener el JWT
EMAIL=alaurao@uni.pe
PASSWORD=s@mmd7ca91
#JSON_PAYLOAD=$(jq -n -c --arg email "$EMAIL" --arg password "$PASSWORD" '$ARGS.named')
#TOKEN=$(curl -s -H "Content-Type: application/json" \
#  -d "$JSON_PAYLOAD" \
#  "https://auth.beta.husarnet.com/token?grant_type=password" | jq -r .access_token)

#JSON_PAYLOAD=$(jq -n -c --arg email "$EMAIL" --arg password "$PASSWORD" '$ARGS.named')
#curl -s -H"Content-Type: application/json" -d "$JSON_PAYLOAD" https://auth.husarnet.com/token?grant_type=password | jq -r .access_token

#curl -s -H "Content-Type: application/json" \
#  -d "$JSON_PAYLOAD" \
#  "https://auth.husarnet.com/token?grant_type=password"


SECRET=$(sudo cat /var/lib/husarnet/daemon_api_token)

# Listar grupos
curl -s -H "X-Husarnet-Secret: $SECRET" \
  localhost:16216/api/forward/v3/web/groups | jq .