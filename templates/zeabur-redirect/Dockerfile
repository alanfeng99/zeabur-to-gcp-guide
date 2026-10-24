# 只做轉址的 Zeabur 服務（見 Caddyfile）。Zeabur 的 Dockerfile 服務走 8080。
# base image 經 mirror.gcr.io，避開 Docker Hub 的匿名下載限制。
FROM mirror.gcr.io/library/caddy:2.10-alpine
COPY Caddyfile /etc/caddy/Caddyfile
