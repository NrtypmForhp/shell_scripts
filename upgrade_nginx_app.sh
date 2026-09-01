#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status
FLASK_CONTAINER_NAME="tsync_flask"
NGINX_PROXY_CONTAINER_NAME="nginx_proxy"
NETWORK_NAME="docker_default"
SERVER_IP=$(hostname -I | awk '{print $1}')

read -p "Make sure you are placed (with cd commands) in the main directory with all the python, HTML, JS files!! Are you in the correct directory? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "-*-* Start creating docker and flask files -*-*"
else
    echo "Stopped by the user."
    exit 0
fi

echo "Remove old configurations files if exists"
rm -f -- docker-compose.yml
rm -f -- Dockerfile
rm -f -- nginx.conf
rm -f -- requirements.txt

echo "-*-* Create docker compose yml file *-*-"
cat >docker-compose.yml <<EOL
services:
  tsync_app:
    build: .
    container_name: tsync_flask
    restart: always
    environment:
      - MONGO_URI=mongodb://mongodb_docker_container:27017/
      - S3_ENDPOINT_URL=http://minio-docker-container:9000
      - S3_EXTERNAL_URL=http://${SERVER_IP}:9000
    volumes:
      - ./bot_cache:/app/bot_cache
      - ./sessions:/app/sessions
    networks:
      - docker_default

  nginx_tsync:
    image: nginx:latest
    container_name: nginx_proxy
    #restart: always
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./static:/app/static:ro
    depends_on:
      - tsync_app
    networks:
      - docker_default

networks:
  docker_default:
    external: true
    name: docker_default
EOL

echo "Create Dockerfile"
cat >Dockerfile <<EOL
FROM python:3.13-slim

RUN useradd -m -u 1000 tsync_docker

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

ENV PATH="/home/tsync_docker/.local/bin:${PATH}"

COPY . .

RUN mkdir -p /app/sessions /app/bot_cache && chown -R tsync_docker:tsync_docker /app

USER tsync_docker

CMD ["gunicorn", "--workers", "3", "--bind", "0.0.0.0:8000", "main:app"]
EOL

echo "Create nginx.conf file"
cat >nginx.conf <<'EOL' # Quoting the delimiter prevents Bash from expanding any internal $ variables
server {
    listen 80;

    # Permits max 20MB files
    client_max_body_size 20M;

    location / {
        proxy_pass http://tsync_app:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /static/ {
        alias /app/static/;
        expires 30d;
        add_header Cache-Control "public";
    }
}
EOL

echo "Create python requirements.txt file"
cat >requirements.txt <<EOL
anyio>=4.14.2
APScheduler>=3.11.3
asgiref>=3.12.1
beautifulsoup4>=4.15.0
blinker>=1.9.0
boto3>=1.43.82
botocore>=1.43.82
cachelib>=0.17.0
certifi>=2026.7.22
charset-normalizer>=3.5.1
click>=8.5.0
deep-translator>=1.11.4
Deprecated>=1.3.1
dnspython>=2.8.0
Flask>=3.1.3
Flask-APScheduler>=1.13.1
Flask-Limiter>=4.1.1
Flask-Session>=0.8.0
Flask-WTF>=1.3.0
h11>=0.16.0
h2>=4.4.1
hpack>=4.2.0
httpcore>=1.0.9
httpx>=0.28.1
hyperframe>=6.1.0
idna>=3.19
itsdangerous>=2.2.0
Jinja2>=3.1.6
jmespath>=1.1.0
limits>=5.8.0
MarkupSafe>=3.0.3
msgspec>=0.21.1
nodejs-wheel-binaries>=24.19.0
ordered-set>=4.1.0
packaging>=26.3
pillow>=12.3.0
pymongo>=4.17.0
python-dateutil>=2.9.0.post0
pytz>=2026.3.post1
requests>=2.34.2
s3transfer>=0.19.2
six>=1.17.0
sniffio>=1.3.1
soupsieve>=2.9.2
typing_extensions>=4.16.0
tzlocal>=5.4.4
urllib3>=2.7.0
Werkzeug>=3.1.8
wrapt>=2.3.0
WTForms>=3.2.2
gunicorn>=26.2.0
EOL

read -p "Create a new container (y) or upgrade and backup the existing one (N)? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Creating new docker container"
else
    echo "Stop flask and nginx containers"
    docker stop "$FLASK_CONTAINER_NAME"
    docker stop "$NGINX_PROXY_CONTAINER_NAME"

    echo "Remove old containers"
    docker compose down -v --rmi all

    echo "Recreate docker container with upgraded version"
fi

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  echo "Network '$NETWORK_NAME' already exists. Skipping creation."
else
  echo "Creating network '$NETWORK_NAME'..."
  docker network create "$NETWORK_NAME"
fi

# Ensure directories exist locally on the host
mkdir -p ./sessions ./bot_cache

# Fix ownership on host before mounting (UID 1000 corresponds to tsync_docker)
sudo chown -R 1000:1000 ./sessions ./bot_cache

docker compose up -d --force-recreate

echo "Finished!"
